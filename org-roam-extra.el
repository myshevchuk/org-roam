;;; org-roam-extra.el --- Roam Research replica with Org-mode -*- coding: utf-8; lexical-binding: t -*-

;; Copyright © 2020 Jethro Kuan <jethrokuan95@gmail.com>
;; Copyright © 2020 Mykhailo Shevchuk <mail@mshevchuk.com>

;; Author: Jethro Kuan <jethrokuan95@gmail.com>
;; Contributor: Mykhailo Shevchuk <mail@mshevchuk.com>
;; URL: https://github.com/jethrokuan/org-roam
;; Keywords: org-mode, roam, convenience
;; Version: 1.0.0-rc1
;; Package-Requires: ((emacs "26.1") (dash "2.13") (f "0.17.2") (s "1.12.0") (org "9.3") (emacsql "3.0.0") (emacsql-sqlite "1.0.0"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; This library is an attempt at injecting Roam functionality into Org-mode.
;; This is achieved primarily through building caches for forward links,
;; backward links, and file titles.
;;
;;
;;; Code:
;;;; Library Requires
(require 'org-roam)
(require 'org-ref)

(autoload 'projectile-relevant-open-projects "projectile" "Return a list of open projects.")
(autoload 'persp-switch "persp-mode" "Switch to the perspective with name NAME.")
(autoload 'persp-names "persp-mode" "")

(defvar org-roam-extra-preformat-templates nil
  "Set it to t to skip to preformat templates.
See `org-roam-extra-org-ref-note-fn' for details.")

(defvar org-roam-extra-preformat-keywords '("citekey" . "=key=")
  "The template prompt wildcards to be preformatted.
Only relevant when `org-roam-extra-preformat-templates' is set to
t. This can be a string, a list of strings or a list of cons
cells of strings.

Use only alphanumerical characters, dash and underscore. See
`org-roam-extra-org-ref-note-fn' for implementation details.

1. If the value is a string, a single keyword, it is treated as a
bibtex field name, such as such as =key=. In the following
example all the prompts with =key= keyword will be preformatted,
as well as the corresponding match group %\\1.

\(setq org-roam-extra-preformat-keywords \"=key=\")
\(setq org-roam-capture-templates
      '((\"r\" \"reference\" plain (function org-roam-capture--get-point)
         \"#+ROAM_KEY: %^{=key=}%? fullcite: %\\1\"
         :file-name \"references/${=key=}\"
         :head \"#+TITLE: ${title}\"
         :unnarrowed t)))

2. If the value is a list of strings they are also treated as
bibtex field names. The respective prompts will be preformatted.

\(setq org-roam-extra-preformat-keywords '(\"=key=\" \"title\"))
\(setq org-roam-capture-templates
      '((\"r\" \"reference\" plain (function org-roam-capture--get-point)
         \"#+ROAM_KEY: %^{=key=}%? fullcite: %\\1\"
         :file-name \"references/${=key=}\"
         :head \"#+TITLE: ${title}\"
         :unnarrowed t)))

3. If the value is a list of cons cells, then the car of the cons
cell is treated as a prompt keyword and the cdr as a bibtex field
name, and the latter will be used to retrieve relevenat value
from the bibtex entry. If cdr is omitted, then the car is treated
as the field name.

\(setq org-roam-extra-preformat-keywords
      '((\"citekey\" . \"=key=\")
       (\"type\" . \"=type=\")
       \"title\"))
\(setq org-roam-capture-templates
      '((\"r\" \"reference\" plain (function org-roam-capture--get-point)
         \"#+ROAM_KEY: %^{citekey}%? fullcite: %\\1
          #+TAGS: %^{type}
          This %\\2 deals with ...\"
         :file-name \"references/%<%Y-%m-%d-%H%M%S>_${title}\"
         :head \"#+TITLE: ${title}\"
         :unnarrowed t)))

Consult bibtex-completion package for additional information
about bibtex field names.")

(defvar org-roam-extra-persp-project `("notes" . ,org-roam-directory)
  "Perspective name and path to the project with bibliography notes.
A cons cell. Only relevant when `org-roam-extra-switch-persp' is set to t.

See `org-roam-extra-org-ref-note-fn' for details")

(defvar org-roam-extra-switch-persp nil
  "Set it ot t if you want to switch to the notes perspective.
Set the name of the perspective and the path to the notes project
in `org-roam-extra-persp-project' for this to take effect.

See `org-roam-extra-org-ref-note-fn' for details.")

(defun org-roam-extra--preformat-template (template entry)
  "Helper function for `org-roam-extra--preformat-templates'.
TEMPLATE is an org-roam template and ENTRY is a bibtex entry."
  ;; Handle org-roam-capture part
  (let* ((kwds (if (listp org-roam-extra-preformat-keywords) ; normalize org-roam-extra-preformat-keywords
                   org-roam-extra-preformat-keywords
                 (list org-roam-extra-preformat-keywords)))
         ;; org-capture
         (tp (nth 4 template))          ; org-capture template string
         (plst (cdr template))         ; org-roam capture properties are here
         (rx "\\(%\\^{[[:alnum:]-_]*}\\)") ; regexp for org-capture prompt wildcard
         lst)
    ;; First run:
    ;; 1) Make a list of (rplc-s field-value match-position) for the second run
    ;; 2) replace org-roam-capture wildcards
    (dolist (kwd kwds)
      (let* ((keyword (or (car-safe kwd) kwd))        ; prompt wildcard keyword
             (field-name (or (cdr-safe kwd) kwd)) ; bibtex field name
             (field-value                ; get the bibtex field value
              (or (s-format (concat "${" field-name "}") 'bibtex-completion-apa-get-value entry)
                  nil))                                         ; nil will be used to set back the proper wildcard
             (rplc-s (concat "%^{" (or keyword "citekey") "}")) ; org-capture prompt wildcard
             (rplc-s2 (concat "${" (or keyword "citekey") "}")) ; org-roam-capture prompt wildcard
             (head (plist-get plst :head))  ; org-roam-capture :head template
             (fl-nm (plist-get plst :file-name)) ; org-roam-capture :file-name template
             (i 1)                               ; match counter
             pos)
        ;; Search for rplc-s, set flag m if found
        (while (string-match rx tp pos)
          (if (string= (match-string 1 tp) rplc-s)
              (progn
                (setq pos (length tp))
                (pushnew (list rplc-s field-value i) lst ))
            (setq pos (match-end 1)
                  i (1+ i))))
        ;; Replace org-roam-capture prompt wildcards
        (when (and field-value head )
          (plist-put plst :head (s-replace rplc-s2 field-value head)))
        (when (and field-value fl-nm)
          (plist-put plst :file-name (s-replace rplc-s2 field-value fl-nm)))))
    ;; Second run: replace prompts and propmt matches in org-capture template string
    (dolist (l lst)
      (when (and (nth 1 l) (stringp tp))
        (let ((pos (concat "%\\" (number-to-string (nth 2 l)))))
          ;; replace prompt match wildcards with prompt wildcards
          ;; replace prompt wildcards with bitex field value
          (setq tp (s-replace pos (car l) tp)
                tp (s-replace (car l) (nth 1 l) tp))))
      (setf (nth 4 template) tp))
    template))

(defun org-roam-extra--switch-perspective ()
  "Helper function for `org-roam-extra-org-ref-note-fn'."
  ;; The compiler still yells but it would not be reasonable to put these
  ;; requires in the top level unconditionally.
  (when
      (and (featurep 'projectile)
           (require 'projectile nil t)
           (featurep 'persp-mode)
           (require 'persp-mode nil t))
    (let ((notes-project (cdr org-roam-extra-persp-project))
          (projects (projectile-relevant-open-projects))
          openp)
      (dolist (project projects openp)
        (setq openp (or (f-equal? project notes-project) openp)))
      (when openp
        (let ((p-names (cdr (persp-names))))
          (dolist (p-name p-names)
            (when (s-equals? p-name (car org-roam-extra-persp-project))
              (persp-switch p-name))))))))

;;;###autoload
(defun org-roam-extra-org-ref-notes-fn (citekey)
  "Open an org-roam note associated with the CITEKEY or create a new one.
Set `org-ref-notes-function' to this function if your
bibliorgaphy notes are managed by org-roam and you want some extra
integration between the two packages.

This function allows to use org-roam as a backend for org-ref's
handling of bibliography notes.

Implementation details and features:

1. This funciton first calls `org-roam-find-ref' trying to find the
note file associated with the CITEKEY. The org-roam key can be
set with \'#+ROAM_KEY:\' in-buffer keyword.

2. If the org-roam reference has not been found, the function
calls `org-roam-find-file' passing to it the title associated
with the CITEKEY as retrieved by `bibtex-completion-get-entry'.
The prompt presented by `org-roam-find-file' will thus be
pre-populated with the record title.

3. Optionally, when `org-roam-extra-preformat-templates' is
non-nil, any prompt wildcards in `org-roam-capture-templates'
associated with the bibtex record fields as specified in
`org-roam-extra-preformat-templates' will be preformatted. Both
`org-capture-templates' (%^{}) and
`org-roam-capture-templates' (`s-format', ${}) prompt syntaxes
are supported.

See `org-roam-extra-preformat-keywords' for more details on how
to properly specify prompts for replacement.

Please pay attention when using this feature that by setting
title for preformatting it will be impossible to change it in the
`org-roam-find-file' interactive prompt since all the template
expansions will have taken place by then. All the title wildcards
will be replace with the bibtex field value.

4. Optionally, if you are using projectile and persp-mode and
have a dedicated workspace to work with your org-roam collection,
you may want to set the perspecive name and project path in
`org-roam-extra-persp-project' and `org-roam-extra-switch-persp' to
t. In this case, the perspective will be switched to the org-roam
notes project before calling any org-roam functions."
  (unless org-roam-mode
    (org-roam-mode +1))
  (let ((note-info (list (cons 'ref citekey))))
    ;; Optionally switch to the notes perspective
    (when org-roam-extra-switch-persp
      (org-roam-extra--switch-perspective))
    ;; Find org-roam reference with the CITEKEY
    (unless (ignore-errors (org-roam-find-ref note-info))
      ;; Call org-roam-find-file
      (let* ((bibtex-completion-bibliography (org-ref-find-bibliography))
             (entry (ignore-errors (bibtex-completion-get-entry citekey)))
             (org-roam-capture-templates
              ;; Optionally preformat keywords
              (or
               (when org-roam-extra-preformat-templates
                 (let* ((templates (copy-tree org-roam-capture-templates))
                        result)
                   (dolist (template templates result)
                     (pushnew (org-roam-extra--preformat-template template entry) result))))
               org-roam-capture-templates))
             (title
              (or (s-format "${title}" 'bibtex-completion-apa-get-value entry)
                  "Title not found for this entry. Check your bibtex file.")))
        (org-roam-find-file title)))))

(provide 'org-roam-extra)
;;; org-roam-extra.el ends here
