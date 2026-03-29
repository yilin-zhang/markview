;;; markview-test.el --- Tests for markview -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path
             (file-name-directory
              (directory-file-name (file-name-directory load-file-name))))
(require 'markview)

;;; ── Helpers ───────────────────────────────────────────────────────────────

(defmacro markview-test-with-preview (content &rest body)
  "Insert CONTENT into a temp buffer, open a preview, and run BODY.
Binds `source' and `preview' for use in BODY."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (with-temp-buffer
       (rename-buffer "markview-test-source" t)
       (insert ,content)
       (goto-char (point-min))
       (switch-to-buffer (current-buffer))
       (let ((markview-window-size 0.4)
             (markview-refresh-delay 0)
             (source (current-buffer))
             preview)
         (unwind-protect
             (progn
               (setq preview (markview-open))
               ,@body)
           (when (buffer-live-p source)
             (with-current-buffer source
               (when (buffer-live-p markview-preview-buffer)
                 (markview-close)))))))))

(defun markview-test-overlay-display-at-line (buffer line)
  "Return the first Markview overlay display string on LINE in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line))
      (let ((ovs (cl-remove-if-not
                  (lambda (ov) (overlay-get ov 'markview))
                  (overlays-in (line-beginning-position)
                               (line-end-position)))))
        (when ovs
          (let ((display (cl-loop for ov in ovs
                                  for v = (or (overlay-get ov 'display)
                                              (overlay-get ov 'before-string))
                                  when v return v)))
            (when display
              (substring-no-properties display))))))))

(defun markview-test-line-overlays (buffer line)
  "Return Markview overlays on LINE in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line))
      (cl-remove-if-not
       (lambda (ov) (overlay-get ov 'markview))
       (overlays-in (line-beginning-position) (line-end-position))))))

(defun markview-test-face-has (prop face)
  "Return non-nil when face PROP contains FACE."
  (if (listp prop) (memq face prop) (eq prop face)))

;;; ── Lifecycle tests ───────────────────────────────────────────────────────

(ert-deftest markview-opens-read-only-preview ()
  (markview-test-with-preview "# Hello\n"
    (should (buffer-live-p preview))
    (with-current-buffer preview
      (should buffer-read-only)
      (should markview-preview-mode))
    (should (eq (buffer-local-value 'markview-preview-buffer source) preview))
    (should (eq (buffer-local-value 'markview-source-buffer preview) source))))

(ert-deftest markview-close-cleans-up ()
  (markview-test-with-preview "# Hello\n"
    (markview-close)
    (should-not (buffer-live-p preview))
    (should-not markview-preview-buffer)))

(ert-deftest markview-close-from-preview-side ()
  (markview-test-with-preview "# Hello\n```lua\nreturn {}\n```\n"
    (with-current-buffer preview
      (should (eq (condition-case err (progn (markview-close) 'ok)
                    (error err))
                  'ok)))
    (should-not (buffer-live-p preview))
    (should-not markview-preview-buffer)))

(ert-deftest markview-toggle-opens-and-closes ()
  (save-window-excursion
    (with-temp-buffer
      (rename-buffer "markview-toggle-test" t)
      (insert "# Hi\n")
      (goto-char (point-min))
      (switch-to-buffer (current-buffer))
      (let ((markview-window-size 0.4)
            (markview-refresh-delay 0))
        (markview-toggle)
        (should markview-preview-buffer)
        (markview-toggle)
        (should-not markview-preview-buffer)))))

;;; ── Sync tests ────────────────────────────────────────────────────────────

(ert-deftest markview-syncs-text-via-indirect-buffer ()
  (markview-test-with-preview "# Hello\n"
    (insert "new line\n")
    (markview--source-after-change)
    (with-current-buffer preview
      (markview-refresh)
      (should (string-match-p "new line" (buffer-string))))))

(ert-deftest markview-syncs-point-source-to-preview ()
  (markview-test-with-preview "# One\n# Two\n# Three\n"
    (forward-line 1)
    (end-of-line)
    (markview--source-post-command)
    (with-current-buffer preview
      (should (= (point)
                 (with-current-buffer source (point)))))))

(ert-deftest markview-syncs-point-preview-to-source ()
  (markview-test-with-preview "# One\n# Two\n# Three\n"
    (let ((pw (get-buffer-window preview t)))
      (select-window pw)
      (goto-char (point-min))
      (forward-line 2)
      (end-of-line)
      (markview--preview-post-command)
      (with-current-buffer source
        (should (= (point)
                   (with-current-buffer preview (point))))))))

;;; ── Heading tests ─────────────────────────────────────────────────────────

(ert-deftest markview-renders-atx-heading ()
  (markview-test-with-preview "# Title\n"
    (should (equal (markview-test-overlay-display-at-line preview 1)
                   "◉ Title"))))

(ert-deftest markview-renders-h2-heading ()
  (markview-test-with-preview "## Sub\n"
    (let ((disp (markview-test-overlay-display-at-line preview 1)))
      (should (string-prefix-p " ○" disp))
      (should (string-match-p "Sub" disp)))))

(ert-deftest markview-renders-heading-with-inline ()
  (markview-test-with-preview "# Hello **world**\n"
    (let ((disp (markview-test-overlay-display-at-line preview 1)))
      (should (string-match-p "Hello" disp))
      (should (string-match-p "world" disp))
      (should-not (string-match-p "\\*\\*" disp)))))

;;; ── Code block tests ──────────────────────────────────────────────────────

(ert-deftest markview-renders-code-block-borders ()
  (markview-test-with-preview "```python\nprint(1)\n```\n"
    (let ((top (markview-test-overlay-display-at-line preview 1))
          (bot (markview-test-overlay-display-at-line preview 3)))
      (should (string-prefix-p "┌─ python" top))
      (should (string-prefix-p "└" bot))
      (should (= (string-width top) (string-width bot))))))

(ert-deftest markview-renders-code-block-body ()
  (markview-test-with-preview "```lua\nreturn {}\n```\n"
    (let* ((ov (cl-find-if (lambda (o) (overlay-get o 'display))
                           (markview-test-line-overlays preview 2)))
           (disp (overlay-get ov 'display)))
      (should ov)
      ;; Borders
      (should (markview-test-face-has
               (get-text-property 0 'face disp)
               'markview-code-block-border-face))
      (should (markview-test-face-has
               (get-text-property (1- (length disp)) 'face disp)
               'markview-code-block-border-face)))))

(ert-deftest markview-renders-blank-code-line ()
  (markview-test-with-preview "```\nfirst\n\nthird\n```\n"
    (let ((disp (markview-test-overlay-display-at-line preview 3)))
      (should (string-prefix-p "│" disp))
      (should (string-suffix-p "│" disp)))))

;;; ── Table tests ───────────────────────────────────────────────────────────

(ert-deftest markview-renders-boxed-table ()
  (markview-test-with-preview "| Name | Age |\n|------|-----|\n| Alice | 30 |\n"
    ;; Top border is a before-string on the header line
    (let* ((ovs (markview-test-line-overlays preview 1))
           (top-ov (cl-find-if
                    (lambda (ov) (overlay-get ov 'before-string))
                    ovs)))
      (should top-ov)
      (should (string-prefix-p "┌"
               (substring-no-properties (overlay-get top-ov 'before-string)))))
    ;; Delimiter row → mid border
    (let ((mid (markview-test-overlay-display-at-line preview 2)))
      (should (string-prefix-p "├" mid)))
    ;; Data row
    (let ((row (markview-test-overlay-display-at-line preview 3)))
      (should (string-match-p "Alice" row)))))

(ert-deftest markview-renders-table-inline-content ()
  (markview-test-with-preview "| Name | Score |\n|------|-------|\n| [x](url) | `42` |\n"
    (let ((row (markview-test-overlay-display-at-line preview 3)))
      (should (string-match-p "x" row))
      (should-not (string-match-p "\\[x\\]" row))
      (should (string-match-p "42" row))
      (should-not (string-match-p "`42`" row)))))

;;; ── Blockquote / callout tests ────────────────────────────────────────────

(ert-deftest markview-renders-blockquote ()
  (markview-test-with-preview "> Some quote\n> continues\n"
    (let ((d1 (markview-test-overlay-display-at-line preview 1))
          (d2 (markview-test-overlay-display-at-line preview 2)))
      (should (string-prefix-p "▎" d1))
      (should (string-match-p "Some quote" d1))
      (should (string-prefix-p "▎" d2)))))

(ert-deftest markview-renders-callout ()
  (markview-test-with-preview "> [!WARNING] Be careful\n> Body text\n"
    (let ((title (markview-test-overlay-display-at-line preview 1))
          (body  (markview-test-overlay-display-at-line preview 2)))
      (should (string-match-p "Warning" title))
      (should (string-match-p "Be careful" title))
      (should (string-prefix-p "▎" body))
      (should (string-match-p "Body text" body)))))

;;; ── List tests ────────────────────────────────────────────────────────────

(ert-deftest markview-renders-unordered-list-bullet ()
  (markview-test-with-preview "- Item one\n"
    (let* ((ovs (markview-test-line-overlays preview 1))
           (bullet-ov (cl-find-if
                       (lambda (ov)
                         (let ((d (overlay-get ov 'display)))
                           (and d (string-match-p "●" (substring-no-properties d)))))
                       ovs)))
      (should bullet-ov))))

(ert-deftest markview-renders-checkbox ()
  (markview-test-with-preview "- [x] Done\n- [ ] Todo\n"
    (let* ((done-ovs (markview-test-line-overlays preview 1))
           (done-ov (cl-find-if
                     (lambda (ov)
                       (let ((d (overlay-get ov 'display)))
                         (and d (string-match-p "☑" (substring-no-properties d)))))
                     done-ovs))
           (todo-ovs (markview-test-line-overlays preview 2))
           (todo-ov (cl-find-if
                     (lambda (ov)
                       (let ((d (overlay-get ov 'display)))
                         (and d (string-match-p "☐" (substring-no-properties d)))))
                     todo-ovs)))
      (should done-ov)
      (should todo-ov))))

(ert-deftest markview-renders-ordered-list ()
  (markview-test-with-preview "1. First\n2. Second\n"
    (let* ((ovs (markview-test-line-overlays preview 1))
           (num-ov (cl-find-if
                    (lambda (ov)
                      (let ((d (overlay-get ov 'display)))
                        (and d (string-match-p "1\\." (substring-no-properties d)))))
                    ovs)))
      (should num-ov)
      (should (markview-test-face-has
               (get-text-property 0 'face (overlay-get num-ov 'display))
               'markview-list-bullet-face)))))

;;; ── Inline tests ──────────────────────────────────────────────────────────

(ert-deftest markview-renders-inline-code ()
  (markview-test-with-preview "Use `code` here.\n"
    (let ((ov (cl-find-if
               (lambda (o)
                 (let ((d (overlay-get o 'display)))
                   (and d (equal (substring-no-properties d) "code"))))
               (markview-test-line-overlays preview 1))))
      (should ov)
      (should (markview-test-face-has
               (get-text-property 0 'face (overlay-get ov 'display))
               'markview-inline-code-face)))))

(ert-deftest markview-renders-inline-bold ()
  (markview-test-with-preview "Use **bold** here.\n"
    (let ((ov (cl-find-if
               (lambda (o)
                 (let ((d (overlay-get o 'display)))
                   (and d (equal (substring-no-properties d) "bold"))))
               (markview-test-line-overlays preview 1))))
      (should ov)
      (should (markview-test-face-has
               (get-text-property 0 'face (overlay-get ov 'display))
               'markview-strong-face)))))

(ert-deftest markview-renders-inline-italic ()
  (markview-test-with-preview "Use *italic* here.\n"
    (let ((ov (cl-find-if
               (lambda (o)
                 (let ((d (overlay-get o 'display)))
                   (and d (equal (substring-no-properties d) "italic"))))
               (markview-test-line-overlays preview 1))))
      (should ov)
      (should (markview-test-face-has
               (get-text-property 0 'face (overlay-get ov 'display))
               'markview-emphasis-face)))))

(ert-deftest markview-renders-strikethrough ()
  (markview-test-with-preview "Use ~~old~~ here.\n"
    (let ((ov (cl-find-if
               (lambda (o)
                 (let ((d (overlay-get o 'display)))
                   (and d (equal (substring-no-properties d) "old"))))
               (markview-test-line-overlays preview 1))))
      (should ov)
      (should (markview-test-face-has
               (get-text-property 0 'face (overlay-get ov 'display))
               'markview-strikethrough-face)))))

(ert-deftest markview-renders-link ()
  (markview-test-with-preview "See [docs](https://example.com).\n"
    (let ((ov (cl-find-if
               (lambda (o)
                 (let ((d (overlay-get o 'display)))
                   (and d (string-match-p "docs" (substring-no-properties d)))))
               (markview-test-line-overlays preview 1))))
      (should ov)
      (should (equal (overlay-get ov 'markview-link-url)
                     "https://example.com")))))

(ert-deftest markview-link-is-clickable ()
  (let (opened)
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url &rest _) (setq opened url))))
      (markview-test-with-preview "See [docs](https://example.com).\n"
        (with-current-buffer preview
          (goto-char (point-min))
          (search-forward "See ")
          (markview-open-link-at-point)
          (should (equal opened "https://example.com")))))))

;;; ── Thematic break test ───────────────────────────────────────────────────

(ert-deftest markview-renders-thematic-break ()
  (markview-test-with-preview "---\n"
    (let ((disp (markview-test-overlay-display-at-line preview 1)))
      (should disp)
      (should (string-match-p "─" disp)))))

;;; ── Inline rendering unit tests ───────────────────────────────────────────

(ert-deftest markview-inline-string-strips-bold ()
  (let ((result (markview--render-inline-string "hello **world**")))
    (should (equal (substring-no-properties result) "hello world"))
    (should (markview-test-face-has
             (get-text-property 6 'face result) 'markview-strong-face))))

(ert-deftest markview-inline-string-strips-code ()
  (let ((result (markview--render-inline-string "use `foo` now")))
    (should (equal (substring-no-properties result) "use foo now"))
    (should (markview-test-face-has
             (get-text-property 4 'face result) 'markview-inline-code-face))))

(ert-deftest markview-inline-string-strips-link ()
  (let ((result (markview--render-inline-string "see [docs](url)")))
    (should (equal (substring-no-properties result) "see docs"))
    (should (markview-test-face-has
             (get-text-property 4 'face result) 'markview-link-face))))

(ert-deftest markview-inline-string-strips-strikethrough ()
  (let ((result (markview--render-inline-string "~~old~~ new")))
    (should (equal (substring-no-properties result) "old new"))
    (should (markview-test-face-has
             (get-text-property 0 'face result) 'markview-strikethrough-face))))

(ert-deftest markview-inline-string-handles-image ()
  (let ((result (markview--render-inline-string "![pic](img.png)")))
    (should (string-match-p "pic" (substring-no-properties result)))))

(provide 'markview-test)

;;; markview-test.el ends here
