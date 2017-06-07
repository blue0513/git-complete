;;; git-complete.el -- Linewise completion engine powered by "git grep"

;; Copyright (C) 2017- zk_phi

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA

;; Author: zk_phi
;; URL: http://hins11.yu-yake.com/
;; Version: 0.0.0
;; Package-Requires: ((popup "0.4"))

;; Load this script
;;
;;   (require 'git-completion)
;;
;; and type something in a file under a git repo
;;
;;   ::SHA
;;
;; then `M-x git-completion` completes rest of the line, if suitable
;; one is found in your git repo.
;;
;;   use Digest::SHA qw/sha1_base64/;
;;
;; You may also bind some keys to the command.
;;
;;   (global-set-key (kbd "C-c C-c") 'git-complete)

;;; Change Log:

;; 0.0.0 text release

;;; Code:

(require 'popup)
(require 'cl-lib)

(defgroup git-complete nil
  "Complete lines via git-grep results."
  :group 'git-complete)

(defcustom git-complete-enable-autopair t
  "When non-nil, `git-complete' assumes that the parens are
always balanced, and keep the balance on
completion (i.e. automatically insert close parens together with
open parens, and avoid inserting extra close parens)."
  :type 'boolean
  :group 'git-complete)

(defcustom git-complete-lispy-modes
  '(lisp-mode emacs-lisp-mode scheme-mode
              lisp-interaction-mode gauche-mode scheme-mode
              clojure-mode racket-mode egison-mode)
  "List of lisp-like language modes. Newline is not inserted
after the point by when `git-complete-enable-autopair', in the
modes."
  :type '(repeat symbol)
  :group 'git-complete)

(defcustom git-complete-threshold 0.01
  "Threshold to filter the results from `git grep'. When 0.01 for
example, which is the default value, completion cnadidates which
occupy less than 1% among the grep results are dropped."
  :type 'number
  :group 'git-complete)

(defcustom git-complete-multiline-completion-threshold 0.4
  "Like `git-complete-threshold' but used only during multiline
completion. Set this variable equal or greater than 1.0 to
disable multiline completion"
  :type 'number
  :group 'git-complete)

(defcustom git-complete-enable-omni-completion nil
  "When non-nil and no candidates are found,
shorten the query and search again."
  :type 'boolean
  :group 'git-complete)

;; * utilities

(defun git-complete--trim-string (str &optional trim-query delimited)
  "Remove leading/trailing whitespaces from STR. When TRIM-QUERY
is specified, try to match TRIM-QUERY with STR, and if a match
found, remove characters before the match-beginning in
addition. If TRIM-QUERY is specified but no matches found, return
an empty string. If DELIMITED is specified and STR has more close
parens than open parens, characters outside the unbalanced close
parens (close parens which do not have matching open parens) are
also removed."
  (with-temp-buffer
    (save-excursion (insert str))
    (when trim-query
      (unless (search-forward trim-query nil t)
        (goto-char (point-max))))
    (skip-chars-forward "\s\t")
    (delete-region (point-min) (point))
    (when delimited
      (ignore-errors
        (up-list 1)
        (delete-region (1- (point)) (point-max))))
    (goto-char (point-max))
    (skip-chars-backward "\s\t")
    (delete-region (point) (point-max))
    (buffer-string)))

(defvar-local git-complete--root-dir nil)
(defun git-complete--root-dir ()
  "Find the root directory of this git repo. If the current
directory is not under a git repo, raises an error. This function
caches the result per buffer."
  (or git-complete--root-dir
      (setq git-complete--root-dir
            (cond ((null buffer-file-name) default-directory)
                  ((locate-dominating-file buffer-file-name ".git"))
                  (t (error "Not under a git repository."))))))

;; * autopair utility fns

(defun git-complete--parse-parens (str)
  "Parse str and returns unbalanced parens in the
form (((EXTRA_OPEN . EXEPECTED_CLOSE) ...) . ((EXTRA_CLOSE
. EXPECTED_OPEN) ...))."
  (let (opens closes syntax char)
    (with-temp-buffer
      (save-excursion (insert str))
      (while (progn (skip-syntax-forward "^\\\\()") (not (eobp)))
        (setq char   (char-after)
              syntax (aref (syntax-table) char)) ; (CLASS . PARTNER)
        (cl-case (car syntax)
          ((4)                          ; (string-to-syntax "(")
           (push (cons char (cdr syntax)) opens))
          ((5)                          ; (string-to-syntax ")")
           (if (and opens (= (cdar opens) char))
               (pop opens)
             (push (cons char (cdr syntax)) closes)))
          ((9)                          ; (string-to-syntax "\\")
           (forward-char 1)))
        (forward-char 1)))
    (cons opens closes)))

(defun git-complete--diff-parens (lst1 lst2)
  "Compute differens of two results of `git-complete--parse-parens'."
  (let ((existing-opens (car lst1))
        (added-opens (car lst2))
        (existing-closes (cdr lst1))
        (added-closes (cdr lst2))
        deleted-opens deleted-closes)
    ;; open parens
    (while (and existing-opens added-opens)
      (if (= (caar existing-opens) (caar added-opens))
          (progn (pop existing-opens) (pop added-opens))
        (push (pop existing-opens) deleted-opens)))
    (when existing-opens
      (setq deleted-opens (nconc (nreverse existing-opens) deleted-opens)))
    ;; close parens
    (while (and existing-closes added-closes)
      (if (= (caar existing-closes) (caar added-closes))
          (progn (pop existing-closes) (pop added-closes))
        (push (pop existing-closes) deleted-closes)))
    (when existing-closes
      (setq deleted-closes (nconc (nreverse existing-closes) deleted-closes)))
    ;; result
    (cons (nconc (mapcar (lambda (a) (cons (cdr a) (car a))) deleted-closes) added-opens)
          (nconc (mapcar (lambda (a) (cons (cdr a) (car a))) deleted-opens) added-closes))))

;; * get candidates via git grep

(defun git-complete--get-candidates (query &optional threshold multiline-p omni-p)
  "Get completion candidates with `git grep'."
  (let* ((default-directory (git-complete--root-dir))
         (command (format "git grep -F -h %s %s"
                          (if multiline-p "-A1" "")
                          (shell-quote-argument query)))
         (lines (split-string (shell-command-to-string command) "\n"))
         (hash (make-hash-table :test 'equal))
         (total-count 0))
    (while (and lines (cdr lines))
      (when multiline-p (pop lines))      ; pop the first line
      (let ((str (git-complete--trim-string (pop lines) (when omni-p query) omni-p)))
        (unless (string= "" str)
          (setq total-count (1+ total-count))
          (puthash str (1+ (gethash str hash 0)) hash)))
      (when multiline-p (pop lines)))     ; pop "--"
    (let* ((result nil)
           (threshold (* (or threshold 0) total-count)))
      (maphash (lambda (k v) (push (cons k v) result)) hash)
      (delq nil
            (mapcar (lambda (x) (and (>= (cdr x) threshold) (car x)))
                    (sort result (lambda (a b) (> (cdr a) (cdr b)))))))))

;; * replace substring smartly

(defun git-complete--replace-substring (from to replacement)
  "Replace region between FROM TO with REPLACEMENT and move the
point just after the inserted text. Unlike `replace-string', this
function tries to keep parenthesis balanced and indent the
inserted text (the behavior may disabled via customize options)."
  (let ((deleted (buffer-substring from to)) end)
    (delete-region from to)
    (setq from (goto-char from))
    (insert replacement)
    (save-excursion
      (let (skip-newline)
        (when git-complete-enable-autopair
          (let* ((res (git-complete--diff-parens
                       (git-complete--parse-parens deleted)
                       (git-complete--parse-parens replacement)))
                 (expected (car res))
                 (extra (cdr res)))
            (when expected
              (insert "\n"
                      (if (memq major-mode git-complete-lispy-modes) "" "\n")
                      (apply 'string (mapcar 'cdr expected)))
              (setq skip-newline t))
            (while extra
              (if (looking-at (concat "[\s\t\n]*" (char-to-string (caar extra))))
                  (replace-match "")
                (save-excursion (goto-char from) (insert (char-to-string (cdar extra)))))
              (pop extra))))
        (unless skip-newline (insert "\n")))
      (setq end (point)))
    (indent-region from end)
    (forward-line 1)
    (funcall indent-line-function)
    (back-to-indentation)))

;; * interface

(defvar git-complete--popup-menu-keymap
  (let ((kmap (copy-keymap popup-menu-keymap)))
    (define-key kmap (kbd "TAB") 'popup-select)
    kmap)
  "Keymap for git-complete popup menu.")

(defun git-complete--internal (threshold &optional omni-from)
  (let* ((next-line-p (looking-back "^[\s\t]*"))
         (query (save-excursion
                  (when next-line-p (forward-line -1) (end-of-line))
                  (git-complete--trim-string
                   (buffer-substring (or omni-from (point-at-bol)) (point)))))
         (candidates (when (not (string= query ""))
                       (git-complete--get-candidates query threshold next-line-p omni-from))))
    (cond (candidates
           (let ((completion (popup-menu* candidates :scroll-bar t :isearch t
                                          :keymap git-complete--popup-menu-keymap)))
             (git-complete--replace-substring
              (or omni-from (point-at-bol)) (point) completion)
             (let ((git-complete-enable-omni-completion nil))
               (git-complete--internal git-complete-multiline-completion-threshold))))
          ((and (not next-line-p) git-complete-enable-omni-completion)
           (let ((next-from (save-excursion
                              (when (search-forward-regexp
                                     ".\\_<"
                                     (prog1 (point) (goto-char (or omni-from (point-at-bol)))) t)
                                (point)))))
             (if next-from (git-complete--internal threshold next-from)
               (message "No completions found."))))
          (t
           (message "No completions found.")))))

(defun git-complete ()
  "Complete the line at point with `git grep'."
  (interactive)
  (git-complete--internal git-complete-threshold))

;; * provide

(provide 'git-complete)

;;; git-complete.el ends here
