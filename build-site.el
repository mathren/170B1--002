;; modified from https://systemcrafters.net/publishing-websites-with-org-mode/building-the-site/
;; using also Claude Sonnet 4.6

;; Set the package installation directory so that packages aren't stored in the
;; ~/.emacs.d/elpa path.
(require 'package)
(setq package-user-dir (expand-file-name "./.packages"))
(setq package-archives '(("melpa" . "https://melpa.org/packages/")
                         ("elpa" . "https://elpa.gnu.org/packages/")))

;; Initialize the package system and install dependencies
(package-initialize)
(unless package-archive-contents
  (package-refresh-contents))
(package-install 'htmlize)

;; Load the publishing system
(require 'ox-publish)

(defun mr/get-modified-org-files ()
  "Return a list of Org files modified since the last commit."
  (let* ((default-directory (expand-file-name "./org-content"))
         (modified-files (split-string (shell-command-to-string "git diff --name-only HEAD -- *.org") "\n" t)))
    (mapcar (lambda (file) (expand-file-name file default-directory)) modified-files)))

(defun mr/check-for-all-flag-and-publish ()
  "Check if all is in the command-line arguments."
  (if (member "all" command-line-args)
      (org-publish-all t) ;; publish all
    (let ((modified-files (mr/get-modified-org-files)))
      (if modified-files
	  (org-publish-project "org-site:main")
	(message "No modified Org files found.")))
    ))

(defun mr/read-file (file)
  "Read contents of FILE to string"
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

;; Dynamically make footer with pointers to previous and next page
(defun mr/get-html-link (org-file publishing-directory)
  "Convert ORG-FILE to the corresponding HTML file in PUBLISHING-DIRECTORY."
  (when org-file
    (let* ((file-name (file-name-sans-extension org-file))
           (html-file (concat file-name ".html")))
      html-file)))

(defun mr/read-navigation-keywords ()
  "Read the keywords #+PREVIOUS_PAGE and #+NEXT_PAGE from the current Org file.
Return them as two values: previous-page and next-page."
  (let* ((keywords (org-element-map (org-element-parse-buffer) 'keyword
                                   (lambda (el) (cons (org-element-property :key el)
                                                      (org-element-property :value el)))))
         (previous (cdr (assoc "PREVIOUS_PAGE" keywords)))
         (next (cdr (assoc "NEXT_PAGE" keywords))))
    (list previous next)))

(defun mr/html-postamble (info)
  "Generate a dynamic HTML footer for the Org export.
Substitute placeholders PREVIOUS_PAGE and NEXT_PAGE with corresponding links.
INFO is the export plist."
  (let* ((publishing-directory (plist-get info :publishing-directory))
         (nav (mr/read-navigation-keywords))
         (previous-page (mr/get-html-link (car nav) publishing-directory))
         (next-page (mr/get-html-link (cadr nav) publishing-directory))
         (footer-template (mr/read-file "../html-content/html-templates/postamble.html"))
         (footer (format footer-template
                         (format-time-string "%-d %B %Y")
                         emacs-version
                         org-version)))
    (setq footer (replace-regexp-in-string "PREVIOUS_PAGE" (or previous-page "#") footer t t))
    (setq footer (replace-regexp-in-string "NEXT_PAGE" (or next-page "#") footer t t))
    ))

(defconst mr/site-html-head
  (mr/read-file "html-content/html-templates/html_head.html"))

(defconst mr/site-html-preamble
  (mr/read-file "html-content/html-templates/preamble.html"))

;; fix timestamps for html and latex exports
(defun mr/filter-timestamp (trans back _comm)
  "Remove <> around time-stamps."
  (pcase back
    (`html
     (replace-regexp-in-string "&[lg]t;" "" trans))
    (`latex
     (replace-regexp-in-string "[<>]" "" trans))))

;; fix export of Sun symbol
(defun mr/export-odot-html (backend)
  "Custom filter to replace LaTeX \\odot with HTML sun symbol."
  (when (org-export-derived-backend-p backend 'html)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\\\\odot" nil t)
        (replace-match "☉" nil t)))))

;; Custom drawer export for click-to-reveal
(defvar mr/drawer-counter 0
  "Counter for deterministic drawer IDs.")

(add-hook 'org-export-before-processing-hook
          (lambda (_)
            (clrhash mr/id-map)
            (setq mr/id-counter 0)
            (setq mr/drawer-counter 0)))

(defun mr/format-drawer-html (drawer contents info)
  "Export DRAWER as a collapsible HTML element."
  (let* ((drawer-name (org-element-property :drawer-name drawer))
         (drawer-id (format "drawer-%s-%d"
                            (replace-regexp-in-string "[^a-zA-Z0-9]" "-" drawer-name)
                            (cl-incf mr/drawer-counter))))
    (format "<div class=\"org-drawer-container\">
  <button class=\"org-drawer-toggle\" onclick=\"toggleDrawer('%s')\">%s ▼</button>
  <div id=\"%s\" class=\"org-drawer-content\" style=\"display: none;\">%s</div>
</div>"
            drawer-id
            drawer-name
            drawer-id
            (or contents ""))))

(advice-add 'org-html-drawer :override #'mr/format-drawer-html)

;; set default image width 100% in html
(defun mr/org-html-default-image-width (orig-fun source attributes info)
  (unless (plist-get attributes :width)
    (setq attributes (plist-put attributes :width "100%")))
  (funcall orig-fun source attributes info))

(advice-add 'org-html--format-image :around #'mr/org-html-default-image-width)

;; ---------------------------------------------------------------------------
;; Deterministic HTML IDs (override in-memory, never touch *.org files)
;; ---------------------------------------------------------------------------

(defun mr/slugify (text)
  "Convert TEXT to a URL-friendly slug."
  (downcase
   (replace-regexp-in-string
    "-+$" ""
    (replace-regexp-in-string
     "^-+" ""
     (replace-regexp-in-string
      "[^a-z0-9]+" "-" text)))))

(defvar mr/id-map (make-hash-table :test 'equal)
  "Map from random org IDs (e.g. org16891ee) to deterministic slugs.")

(defvar mr/id-counter 0
  "Counter for fallback deterministic IDs (figures, latex blocks, etc.).")

;; Reset state before each file export
(add-hook 'org-export-before-processing-hook
          (lambda (_)
            (clrhash mr/id-map)
            (setq mr/id-counter 0)))

(defun mr/headline-html (orig-fun headline contents info)
  "Around advice for org-html-headline to inject deterministic slug IDs.
Also populates mr/id-map for use by mr/fix-remaining-ids."
  (let* ((custom-id (org-element-property :CUSTOM_ID headline))
         (title (org-export-data (org-element-property :title headline) info))
         (slug (or custom-id (mr/slugify title))))
    (org-element-put-property headline :CUSTOM_ID slug)
    (let ((result (funcall orig-fun headline contents info)))
      (when (string-match "outline-container-\\(org[a-f0-9]\\{7\\}\\)" result)
        (puthash (match-string 1 result) slug mr/id-map))
      result)))

(advice-add 'org-html-headline :around #'mr/headline-html)

(defun mr/fix-remaining-ids (output backend info)
  "Replace all remaining random org IDs in the final HTML output.
IDs mapped via mr/id-map (from headlines) get their slug.
All other random IDs (figures, latex blocks, etc.) get a counter-based ID."
  (when (org-export-derived-backend-p backend 'html)
    (replace-regexp-in-string
     "org[a-f0-9]\\{7\\}"
     (lambda (match)
       (or (gethash match mr/id-map)
           (progn (cl-incf mr/id-counter)
                  (format "org-element-%d" mr/id-counter))))
     output)))

(add-to-list 'org-export-filter-final-output-functions #'mr/fix-remaining-ids)

;; ---------------------------------------------------------------------------

(add-hook 'org-export-before-processing-hook 'mr/export-odot-html)
(add-to-list 'org-export-filter-timestamp-functions #'mr/filter-timestamp)

;; Customize the HTML output
(setq org-html-validation-link nil            ;; Don't show validation link
      org-html-head-include-scripts nil       ;; Use our own scripts
      org-html-head-include-default-style nil ;; Use our own styles
      user-full-name "Mathieu Renzo"          ;; for creator
      org-html-head mr/site-html-head
      org-html-preamble mr/site-html-preamble
      org-html-postamble #'mr/html-postamble
      org-display-custom-times t
      org-latex-image-default-width "0.5\\textwidth"
)

;; define the publishing project
(setq org-publish-project-alist
      (list
       (list "org-site:main"
             :base-directory "./org-content"
	     :publishing-directory "./html-content"
	     :recursive t
	     :exclude "LICENSE\\|\\.gitignore"
             :publishing-function 'org-html-publish-to-html
	     :html-doctype "html5"
	     :language "en"
	     :html-html5-fancy t
	     :email "mrenzo@arizona.edu"
	     :meta-type "website"
	     :description: "Website for ASTR170B1 -- 002"
	     :with-title nil
	     :with-latex t
	     :with-sub-superscript t
	     :with-tags t
	     :with-tasks t
	     :html-self-link-headlines t
             :with-timestamps t				;; Include time stamp in file
             :with-toc nil				;; Don't include a table of contents
             :section-numbers nil			;; Don't include section numbers
             :file-list (mr/get-modified-org-files)	;; Use the list of modified files only
	     )))

;; Generate the site output
(mr/check-for-all-flag-and-publish)
(message "Build complete!")
