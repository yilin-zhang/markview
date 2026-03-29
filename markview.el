;;; markview.el --- Markdown split-view preview via tree-sitter -*- lexical-binding: t; -*-

;; Author: Yilin Zhang
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/yilinzhang/markview.el
;; Keywords: convenience, text, markdown

;;; Commentary:

;; Read-only Markdown preview in a side window.  Uses tree-sitter for block
;; structure parsing and overlays for rendering.  Inspired by markview.nvim.
;;
;; Entry points: `markview-open', `markview-close', `markview-toggle'.

;;; Code:

(require 'cl-lib)
(require 'browse-url)
(require 'treesit)

;;; ── Faces ─────────────────────────────────────────────────────────────────

(defgroup markview nil
  "Markdown split-view preview."
  :group 'text)

(defface markview-heading-1-face
  '((t :weight bold :height 1.45))
  "Face for level-1 headings."
  :group 'markview)

(defface markview-heading-2-face
  '((t :weight bold :height 1.30))
  "Face for level-2 headings."
  :group 'markview)

(defface markview-heading-3-face
  '((t :weight bold :height 1.18))
  "Face for level-3 headings."
  :group 'markview)

(defface markview-heading-4-face
  '((t :weight bold :height 1.08))
  "Face for level-4 headings."
  :group 'markview)

(defface markview-heading-5-face
  '((t :weight semi-bold))
  "Face for level-5 headings."
  :group 'markview)

(defface markview-heading-6-face
  '((t :slant italic))
  "Face for level-6 headings."
  :group 'markview)

(defface markview-callout-face
  '((t :inherit font-lock-doc-face :extend t))
  "Face for callout body."
  :group 'markview)

(defface markview-callout-title-face
  '((t :inherit (font-lock-doc-face bold) :extend t))
  "Face for callout title line."
  :group 'markview)

(defface markview-quote-face
  '((t :inherit shadow :slant italic :extend t))
  "Face for block quotes."
  :group 'markview)

(defface markview-code-block-border-face
  '((t :inherit shadow :extend t))
  "Face for code block borders."
  :group 'markview)

(defface markview-code-block-body-face
  '((t :inherit fixed-pitch :extend t))
  "Face for code block body lines."
  :group 'markview)

(defface markview-rule-face
  '((t :inherit shadow))
  "Face for horizontal rules."
  :group 'markview)

(defface markview-checkbox-done-face
  '((t :inherit success :weight bold))
  "Face for checked checkboxes."
  :group 'markview)

(defface markview-checkbox-todo-face
  '((t :inherit warning :weight bold))
  "Face for unchecked checkboxes."
  :group 'markview)

(defface markview-table-border-face
  '((t :inherit shadow :extend t))
  "Face for table borders."
  :group 'markview)

(defface markview-table-face
  '((t :inherit fixed-pitch :extend t))
  "Face for table cell content."
  :group 'markview)

(defface markview-link-face
  '((t :inherit link :underline t))
  "Face for links."
  :group 'markview)

(defface markview-inline-code-face
  '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Face for inline code spans."
  :group 'markview)

(defface markview-strong-face
  '((t :weight bold))
  "Face for strong emphasis."
  :group 'markview)

(defface markview-emphasis-face
  '((t :slant italic))
  "Face for emphasis."
  :group 'markview)

(defface markview-strikethrough-face
  '((t :strike-through t))
  "Face for strikethrough text."
  :group 'markview)

(defface markview-list-bullet-face
  '((t :inherit font-lock-keyword-face))
  "Face for list bullets."
  :group 'markview)

;;; ── Customization ─────────────────────────────────────────────────────────

(defcustom markview-window-size 0.5
  "Width of the preview side window (fraction of frame width)."
  :type '(choice integer float)
  :group 'markview)

(defcustom markview-refresh-delay 0.08
  "Idle seconds before refreshing preview after a source edit."
  :type 'number
  :group 'markview)

(defcustom markview-heading-bullets ["◉" "○" "✦" "◆" "▸" "·"]
  "Bullets for heading levels 1–6."
  :type '(vector string string string string string string)
  :group 'markview)

(defcustom markview-list-bullets ["●" "○" "◆" "◇" "▸" "▹"]
  "Bullets for unordered list nesting depths 0–5."
  :type '(vector string string string string string string)
  :group 'markview)

(defcustom markview-callout-labels
  '(("NOTE"      . "Note")
    ("TIP"       . "Tip")
    ("IMPORTANT" . "Important")
    ("WARNING"   . "Warning")
    ("CAUTION"   . "Caution")
    ("INFO"      . "Info")
    ("SUCCESS"   . "Success")
    ("QUESTION"  . "Question")
    ("DANGER"    . "Danger")
    ("ERROR"     . "Error")
    ("BUG"       . "Bug")
    ("EXAMPLE"   . "Example")
    ("QUOTE"     . "Quote"))
  "Display names for callout types."
  :type '(alist :key-type string :value-type string)
  :group 'markview)

(defcustom markview-callout-icons
  '(("NOTE"      . "󰋽")
    ("TIP"       . "󰌶")
    ("IMPORTANT" . "󰅾")
    ("WARNING"   . "\N{U+F0028}")
    ("CAUTION"   . "\N{U+F0028}")
    ("INFO"      . "󰋼")
    ("SUCCESS"   . "󰄬")
    ("QUESTION"  . "󰘥")
    ("DANGER"    . "󱐌")
    ("ERROR"     . "󰅚")
    ("BUG"       . "󰨰")
    ("EXAMPLE"   . "󰉹")
    ("QUOTE"     . "󱆨"))
  "Icons for callout types (requires a Nerd Font)."
  :type '(alist :key-type string :value-type string)
  :group 'markview)

;;; ── Internal variables ────────────────────────────────────────────────────

(defvar markview--syncing nil
  "Non-nil while sync is in progress, to prevent recursion.")

(defvar-local markview--overlays nil
  "List of active Markview overlays in this buffer.")

(defvar-local markview--refresh-timer nil
  "Idle timer for debounced preview refresh.")

(defvar-local markview-source-buffer nil
  "In a preview buffer, the associated source buffer.")

(defvar-local markview-preview-buffer nil
  "In a source buffer, the associated preview buffer.")

;;; ── Keymaps ───────────────────────────────────────────────────────────────

(defvar markview-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'markview-close)
    (define-key map (kbd "RET") #'markview-open-link-at-point)
    map)
  "Keymap for the Markview preview buffer.")

(defvar markview-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'markview-open-link-at-point)
    (define-key map [mouse-1] #'markview-open-link-at-mouse)
    map)
  "Keymap for clickable link overlays.")

;;; ── Overlay utilities ─────────────────────────────────────────────────────

(defun markview--make-overlay (beg end &rest props)
  "Create an overlay from BEG to END with PROPS and register it."
  (let ((ov (make-overlay beg end nil t t)))
    (overlay-put ov 'markview t)
    (overlay-put ov 'priority 1000)
    (while props
      (overlay-put ov (pop props) (pop props)))
    (push ov markview--overlays)
    ov))

(defun markview--make-link-overlay (beg end display url)
  "Create a clickable link overlay from BEG to END.
DISPLAY is the rendered string, URL the link target."
  (markview--make-overlay
   beg end
   'display display
   'markview-link-url url
   'keymap markview-link-map
   'mouse-face 'highlight
   'follow-link t
   'help-echo url))

(defun markview-clear ()
  "Remove all Markview overlays in the current buffer."
  (interactive)
  (when markview--refresh-timer
    (cancel-timer markview--refresh-timer)
    (setq markview--refresh-timer nil))
  (mapc #'delete-overlay markview--overlays)
  (setq markview--overlays nil))

(defun markview--set-line-display (beg end string &optional face)
  "Replace BEG..END with STRING.  Apply FACE on top when non-nil."
  (let ((display (if face
                     (let ((s (copy-sequence string)))
                       (add-face-text-property 0 (length s) face t s)
                       s)
                   string)))
    (if (= beg end)
        (markview--make-overlay beg end 'before-string display)
      (markview--make-overlay beg end 'display display))))

(defun markview--fill-default-face (string face)
  "Apply FACE to regions of STRING that have no face set."
  (let ((pos 0))
    (while (< pos (length string))
      (let ((next (or (next-single-property-change pos 'face string)
                      (length string))))
        (unless (get-text-property pos 'face string)
          (add-face-text-property pos next face t string))
        (setq pos next))))
  string)

(defun markview--display-width (string)
  "Return the display width of STRING in columns.
Uses `string-pixel-width' for accurate measurement of characters
whose rendered width differs from `string-width' (e.g. Nerd Font icons)."
  (let ((space-px (string-pixel-width " ")))
    (if (> space-px 0)
        (round (/ (float (string-pixel-width string)) space-px))
      (string-width string))))

;;; ── Tree-sitter helpers ───────────────────────────────────────────────────

(defun markview--find-child (node type)
  "Return the first named child of NODE with TYPE."
  (cl-find-if (lambda (n) (string= (treesit-node-type n) type))
              (treesit-node-children node t)))

(defun markview--node-line-range (node)
  "Return (BEG . END) for the line containing NODE's start."
  (save-excursion
    (goto-char (treesit-node-start node))
    (cons (line-beginning-position) (line-end-position))))

(defun markview--node-text (node)
  "Return the text of the `inline' child of NODE, or \"\"."
  (let ((inline (markview--find-child node "inline")))
    (if inline (treesit-node-text inline t) "")))

(defun markview--heading-face (level)
  "Return heading face for LEVEL (1–6)."
  (intern (format "markview-heading-%d-face" (min 6 (max 1 level)))))

(defun markview--preview-buffer-name (buffer)
  "Return the preview buffer name for BUFFER."
  (format "*markview:%s*" (buffer-name buffer)))

(defun markview--ensure-parser ()
  "Return a markdown tree-sitter parser for the source buffer.
Creates one if none exists."
  (let ((source (or markview-source-buffer (current-buffer))))
    (with-current-buffer source
      (or (car (treesit-parser-list nil 'markdown))
          (treesit-parser-create 'markdown)))))

;;; ── Inline rendering ──────────────────────────────────────────────────────

(defconst markview--inline-re
  (concat
   "`\\([^`]+\\)`"                                          ; 1  code span
   "\\|!\\[\\([^]]*\\)\\](\\([^)]*\\))"                    ; 2,3  image
   "\\|\\[\\([^]]+\\)\\](\\([^)]*\\))"                     ; 4,5  link
   "\\|<\\(https?://[^>]+\\)>"                              ; 6  autolink
   "\\|\\*\\*\\([^*]+\\)\\*\\*"                             ; 7  bold
   "\\|~~\\([^~]+\\)~~"                                     ; 8  strikethrough
   "\\|\\*\\([^*]+\\)\\*")                                  ; 9  italic
  "Combined regex for inline Markdown elements.
Alternatives are ordered by priority: code > image > link > autolink >
bold > strikethrough > italic.")

(defun markview--render-link-display (label url is-image)
  "Return a propertized display string for a link.
LABEL is the visible text, URL the target, IS-IMAGE non-nil for images."
  (propertize (if is-image (format "󰈚 %s" label) label)
              'face 'markview-link-face
              'help-echo url))

(defun markview--image-label (alt url)
  "Return the display label for an image with ALT text and URL."
  (if (string-empty-p alt) (file-name-nondirectory url) alt))

(defun markview--inline-match-to-styled (text)
  "Return a propertized string for the current inline match in TEXT.
Caller must have just matched `markview--inline-re' against TEXT."
  (cond
   ((match-beginning 1)
    (propertize (match-string 1 text) 'face 'markview-inline-code-face))
   ((match-beginning 2)
    (markview--render-link-display
     (markview--image-label (match-string 2 text) (match-string 3 text))
     (match-string 3 text) t))
   ((match-beginning 4)
    (markview--render-link-display (match-string 4 text)
                                    (match-string 5 text) nil))
   ((match-beginning 6)
    (markview--render-link-display (match-string 6 text)
                                    (match-string 6 text) nil))
   ((match-beginning 7)
    (propertize (match-string 7 text) 'face 'markview-strong-face))
   ((match-beginning 8)
    (propertize (match-string 8 text) 'face 'markview-strikethrough-face))
   ((match-beginning 9)
    (propertize (match-string 9 text) 'face 'markview-emphasis-face))))

(defun markview--render-inline-string (text)
  "Return TEXT with inline Markdown rendered as a propertized string.
Used for display-string contexts (headings, table cells, quote bodies)."
  (let ((pos 0)
        parts)
    (while (and (< pos (length text))
                (string-match markview--inline-re text pos))
      (when (> (match-beginning 0) pos)
        (push (substring text pos (match-beginning 0)) parts))
      (push (markview--inline-match-to-styled text) parts)
      (setq pos (match-end 0)))
    (when (< pos (length text))
      (push (substring text pos) parts))
    (apply #'concat (nreverse parts))))

(defun markview--inline-match-url (text)
  "Return the URL from the current inline match in TEXT, or nil."
  (cond
   ((match-beginning 2) (match-string 3 text))
   ((match-beginning 4) (match-string 5 text))
   ((match-beginning 6) (match-string 6 text))))

(defun markview--apply-inline-overlays (beg end)
  "Create overlays for inline Markdown elements between BEG and END."
  (let ((text (buffer-substring-no-properties beg end))
        (pos 0))
    (while (and (< pos (length text))
                (string-match markview--inline-re text pos))
      (let ((mbeg (+ beg (match-beginning 0)))
            (mend (+ beg (match-end 0)))
            (styled (markview--inline-match-to-styled text))
            (url (markview--inline-match-url text)))
        (if url
            (markview--make-link-overlay mbeg mend styled url)
          (markview--make-overlay mbeg mend 'display styled)))
      (setq pos (match-end 0)))))

;;; ── Block renderers ───────────────────────────────────────────────────────

;; ---- Headings ----------------------------------------------------------

(defun markview--render-heading (node)
  "Render an ATX heading NODE."
  (let* ((marker (treesit-node-child node 0))
         (level (length (string-trim (treesit-node-text marker t))))
         (title (markview--node-text node))
         (bullet (aref markview-heading-bullets (1- (min 6 level))))
         (prefix (make-string (max 0 (1- level)) ?\s))
         (display (concat prefix bullet " "
                          (markview--render-inline-string title)))
         (range (markview--node-line-range node)))
    (markview--set-line-display (car range) (cdr range) display
                                (markview--heading-face level))))

(defun markview--render-setext-heading (node)
  "Render a setext heading NODE."
  (save-excursion
    (goto-char (treesit-node-start node))
    (let* ((title-beg (line-beginning-position))
           (title-end (line-end-position))
           (title (buffer-substring-no-properties title-beg title-end)))
      (forward-line 1)
      (let* ((ul-beg (line-beginning-position))
             (ul-end (line-end-position))
             (ul (buffer-substring-no-properties ul-beg ul-end))
             (level (if (string-match-p "^=+" ul) 1 2))
             (bullet (aref markview-heading-bullets (1- level)))
             (display (concat bullet " "
                              (markview--render-inline-string
                               (string-trim title)))))
        (markview--set-line-display title-beg title-end display
                                    (markview--heading-face level))
        (markview--set-line-display ul-beg ul-end "" nil)))))

;; ---- Code blocks -------------------------------------------------------

(defun markview--collect-node-lines (node)
  "Return an alist of (BEG . END) for each line in NODE."
  (let (lines)
    (save-excursion
      (goto-char (treesit-node-start node))
      (while (< (point) (treesit-node-end node))
        (push (cons (line-beginning-position) (line-end-position)) lines)
        (forward-line 1)))
    (nreverse lines)))

(defun markview--render-fenced-code-block (node)
  "Render a fenced code block NODE with box-drawing borders."
  (let* ((lang-node (when-let ((info (markview--find-child node "info_string")))
                      (markview--find-child info "language")))
         (lang (if lang-node (string-trim (treesit-node-text lang-node t)) ""))
         (lines (markview--collect-node-lines node)))
    (when (>= (length lines) 2)
      (let* ((open-cell  (car lines))
             (close-cell (car (last lines)))
             (body-cells (butlast (cdr lines)))
             (body-texts (mapcar (lambda (c)
                                   (buffer-substring-no-properties (car c) (cdr c)))
                                 body-cells))
             (width (max 20
                         (+ (markview--display-width lang) 2)
                         (if body-texts
                             (apply #'max 0 (mapcar #'markview--display-width body-texts))
                           0)))
             (fill (max 0 (- width (markview--display-width lang) 1)))
             (border 'markview-code-block-border-face)
             (top (propertize
                   (if (string-empty-p lang)
                       (concat "┌" (make-string (+ width 2) ?─) "┐")
                     (concat "┌─ " lang " " (make-string fill ?─) "┐"))
                   'face border))
             (bot (propertize
                   (concat "└" (make-string (+ width 2) ?─) "┘")
                   'face border)))
        (markview--set-line-display (car open-cell) (cdr open-cell) top nil)
        (dolist (cell body-cells)
          (let* ((raw (buffer-substring (car cell) (cdr cell)))
                 (text (copy-sequence raw))
                 (pad (make-string (max 0 (- width (markview--display-width raw))) ?\s)))
            (markview--fill-default-face text 'markview-code-block-body-face)
            (markview--set-line-display
             (car cell) (cdr cell)
             (concat (propertize "│ " 'face border)
                     text
                     (propertize pad 'face 'markview-code-block-body-face)
                     (propertize " │" 'face border))
             nil)))
        (markview--set-line-display (car close-cell) (cdr close-cell) bot nil)))))

;; ---- Tables ------------------------------------------------------------

(defun markview--table-cells (row-node)
  "Return trimmed cell text strings from ROW-NODE."
  (let (cells)
    (dolist (child (treesit-node-children row-node t))
      (when (string-match-p "^pipe_table_\\(?:cell\\|delimiter_cell\\)"
                            (treesit-node-type child))
        (push (string-trim (treesit-node-text child t)) cells)))
    (nreverse cells)))

(defun markview--cell-alignment (delim-text)
  "Return alignment symbol from DELIM-TEXT (e.g. \":---:\")."
  (let ((s (string-trim delim-text)))
    (cond
     ((and (string-prefix-p ":" s) (string-suffix-p ":" s)) 'center)
     ((string-suffix-p ":" s) 'right)
     (t 'left))))

(defun markview--table-border (left cross right widths)
  "Build a table border string from LEFT, CROSS, RIGHT and WIDTHS."
  (propertize
   (concat left
           (mapconcat (lambda (w) (make-string (+ w 2) ?─)) widths cross)
           right)
   'face 'markview-table-border-face))

(defun markview--pad-to-width (text width align face)
  "Pad TEXT to WIDTH according to ALIGN, filling pad with FACE."
  (let ((pad (max 0 (- width (markview--display-width text)))))
    (pcase align
      ('right
       (concat (propertize (make-string pad ?\s) 'face face) text))
      ('center
       (let ((l (/ pad 2))
             (r (- pad (/ pad 2))))
         (concat (propertize (make-string l ?\s) 'face face)
                 text
                 (propertize (make-string r ?\s) 'face face))))
      (_
       (concat text (propertize (make-string pad ?\s) 'face face))))))

(defun markview--table-row-string (cells widths alignments)
  "Build a display string for one table row.
CELLS is a list of raw cell strings, WIDTHS per-column display widths,
ALIGNMENTS per-column alignment symbols."
  (let (parts)
    (dotimes (col (length widths))
      (let* ((styled (markview--render-inline-string (or (nth col cells) "")))
             (align  (or (nth col alignments) 'left)))
        (markview--fill-default-face styled 'markview-table-face)
        (push (markview--pad-to-width styled (nth col widths) align
                                       'markview-table-face)
              parts)))
    (let ((sep (propertize " │ " 'face 'markview-table-border-face)))
      (concat (propertize "│ " 'face 'markview-table-border-face)
              (mapconcat #'identity (nreverse parts) sep)
              (propertize " │" 'face 'markview-table-border-face)))))

(defun markview--render-pipe-table (node)
  "Render a pipe table NODE with box-drawing borders."
  (let (header-node delim-node row-nodes)
    (dolist (child (treesit-node-children node t))
      (pcase (treesit-node-type child)
        ("pipe_table_header"        (setq header-node child))
        ("pipe_table_delimiter_row" (setq delim-node child))
        ("pipe_table_row"           (push child row-nodes))))
    (setq row-nodes (nreverse row-nodes))
    (when (and header-node delim-node)
      (let* ((header-cells (markview--table-cells header-node))
             (delim-cells  (markview--table-cells delim-node))
             (rows-cells   (mapcar #'markview--table-cells row-nodes))
             (alignments   (mapcar #'markview--cell-alignment delim-cells))
             (all-rows     (cons header-cells rows-cells))
             (ncols        (apply #'max 1 (mapcar #'length all-rows)))
             (widths
              (cl-loop for col from 0 below ncols
                       collect (apply #'max 1
                                      (mapcar
                                       (lambda (row)
                                         (markview--display-width
                                          (markview--render-inline-string
                                           (or (nth col row) ""))))
                                       all-rows))))
             (top (markview--table-border "┌" "┬" "┐" widths))
             (mid (markview--table-border "├" "┼" "┤" widths))
             (bot (markview--table-border "└" "┴" "┘" widths)))
        ;; Top border
        (markview--make-overlay
         (treesit-node-start header-node) (treesit-node-start header-node)
         'before-string (propertize (concat top "\n")
                                    'face 'markview-table-border-face))
        ;; Header, delimiter, data rows
        (dolist (pair `((,header-node . ,header-cells)
                        (,delim-node  . nil)
                        ,@(mapcar (lambda (rn)
                                    (cons rn (markview--table-cells rn)))
                                  row-nodes)))
          (let ((range (markview--node-line-range (car pair))))
            (markview--set-line-display
             (car range) (cdr range)
             (if (cdr pair)
                 (markview--table-row-string (cdr pair) widths alignments)
               mid)
             nil)))
        ;; Bottom border
        (let* ((last (or (car (last row-nodes)) delim-node))
               (eol (cdr (markview--node-line-range last))))
          (markview--make-overlay
           eol eol
           'after-string (propertize (concat "\n" bot)
                                     'face 'markview-table-border-face)))))))

;; ---- Block quotes / callouts -------------------------------------------

(defun markview--callout-title (kind title)
  "Return formatted callout title for KIND with optional TITLE."
  (let* ((upper (upcase kind))
         (label (or (cdr (assoc upper markview-callout-labels)) upper))
         (icon  (or (cdr (assoc upper markview-callout-icons)) "󰞋")))
    (if (string-empty-p title)
        (format "▎ %s  %s" icon label)
      (format "▎ %s  %s — %s" icon label title))))

(defun markview--render-block-quote (node)
  "Render a block quote NODE (plain quote or callout)."
  (save-excursion
    (goto-char (treesit-node-start node))
    (let ((end (treesit-node-end node))
          (first t)
          is-callout)
      (while (< (point) end)
        (let* ((lbeg (line-beginning-position))
               (lend (line-end-position))
               (line (buffer-substring-no-properties lbeg lend))
               (content (if (string-match "^>[ \t]?\\(.*\\)" line)
                            (match-string 1 line)
                          line)))
          (cond
           ;; Callout title
           ((and first
                 (string-match "^\\[!\\([^]]+\\)\\][ \t]*\\(.*\\)$" content))
            (setq is-callout t)
            (markview--set-line-display
             lbeg lend
             (markview--callout-title (match-string 1 content)
                                      (string-trim (match-string 2 content)))
             'markview-callout-title-face))
           ;; Callout body
           (is-callout
            (markview--set-line-display
             lbeg lend
             (concat (propertize "▎    " 'face 'markview-callout-face)
                     (markview--render-inline-string content))
             nil))
           ;; Regular quote
           (t
            (markview--set-line-display
             lbeg lend
             (concat (propertize "▎ " 'face 'markview-quote-face)
                     (markview--render-inline-string content))
             nil)))
          (setq first nil))
        (forward-line 1)))))

;; ---- Lists -------------------------------------------------------------

(defun markview--render-list (node depth)
  "Render a list NODE at nesting DEPTH."
  (dolist (child (treesit-node-children node t))
    (when (string= (treesit-node-type child) "list_item")
      (markview--render-list-item child depth))))

(defun markview--render-list-item (node depth)
  "Render a single list item NODE at nesting DEPTH."
  (dolist (child (treesit-node-children node t))
    (let ((type (treesit-node-type child)))
      (cond
       ((string-match-p "^list_marker" type)
        (let* ((text (treesit-node-text child t))
               (display (if (string-match-p "\\(?:minus\\|plus\\|star\\)" type)
                            (concat (aref markview-list-bullets (min depth 5)) " ")
                          text)))
          (markview--make-overlay
           (treesit-node-start child) (treesit-node-end child)
           'display (propertize display 'face 'markview-list-bullet-face))))
       ((string= type "task_list_marker_checked")
        (markview--make-overlay
         (treesit-node-start child) (treesit-node-end child)
         'display (propertize "☑ " 'face 'markview-checkbox-done-face)))
       ((string= type "task_list_marker_unchecked")
        (markview--make-overlay
         (treesit-node-start child) (treesit-node-end child)
         'display (propertize "☐ " 'face 'markview-checkbox-todo-face)))
       ((string= type "paragraph")
        (markview--render-paragraph child))
       ((string= type "list")
        (markview--render-list child (1+ depth)))))))

;; ---- Thematic break ----------------------------------------------------

(defun markview--render-thematic-break (node)
  "Render a thematic break NODE as a line of dashes."
  (let ((range (markview--node-line-range node)))
    (markview--set-line-display
     (car range) (cdr range) (make-string 32 ?─) 'markview-rule-face)))

;; ---- Paragraphs --------------------------------------------------------

(defun markview--render-paragraph (node)
  "Apply inline overlays to a paragraph NODE."
  (save-excursion
    (goto-char (treesit-node-start node))
    (while (< (point) (treesit-node-end node))
      (let ((lbeg (line-beginning-position))
            (lend (line-end-position)))
        (when (> lend lbeg)
          (markview--apply-inline-overlays lbeg lend)))
      (forward-line 1))))

;;; ── Tree walker & refresh ─────────────────────────────────────────────────

(defun markview--render-children (node)
  "Render all named children of NODE."
  (dolist (child (treesit-node-children node t))
    (markview--render-node child)))

(defun markview--render-node (node)
  "Dispatch rendering for a tree-sitter NODE."
  (pcase (treesit-node-type node)
    ((or "document" "section") (markview--render-children node))
    ("atx_heading"             (markview--render-heading node))
    ("setext_heading"          (markview--render-setext-heading node))
    ("fenced_code_block"       (markview--render-fenced-code-block node))
    ("pipe_table"              (markview--render-pipe-table node))
    ("block_quote"             (markview--render-block-quote node))
    ("list"                    (markview--render-list node 0))
    ("thematic_break"          (markview--render-thematic-break node))
    ("paragraph"               (markview--render-paragraph node))))

(defun markview-refresh ()
  "Rebuild all preview overlays from the tree-sitter parse tree."
  (interactive)
  (let ((inhibit-modification-hooks t))
    (markview-clear)
    (when (fboundp 'font-lock-ensure)
      (font-lock-ensure (point-min) (point-max)))
    (let* ((parser (markview--ensure-parser))
           (root   (treesit-parser-root-node parser)))
      (markview--render-node root))))

;;; ── Minor mode ────────────────────────────────────────────────────────────

(define-minor-mode markview-preview-mode
  "Render Markdown preview overlays in the current buffer."
  :lighter " Markview"
  (if markview-preview-mode
      (progn
        (setq buffer-read-only t)
        (setq-local cursor-type nil)
        (markview-refresh))
    (kill-local-variable 'cursor-type)
    (markview-clear)))

;;; ── Synchronization ───────────────────────────────────────────────────────

(defun markview--sync-window-state (source preview)
  "Mirror window point and start from SOURCE to PREVIEW."
  (let ((sw (get-buffer-window source t))
        (pw (get-buffer-window preview t)))
    (when (and (window-live-p sw) (window-live-p pw))
      (set-window-point pw (window-point sw))
      (set-window-start pw (window-start sw) t))))

(defun markview--sync-from-buffer (buffer)
  "Synchronize BUFFER and its counterpart."
  (unless markview--syncing
    (let* ((is-preview (buffer-local-value 'markview-source-buffer buffer))
           (source  (if is-preview
                        (buffer-local-value 'markview-source-buffer buffer)
                      buffer))
           (preview (if is-preview
                        buffer
                      (buffer-local-value 'markview-preview-buffer buffer))))
      (when (and (buffer-live-p source) (buffer-live-p preview))
        (let ((markview--syncing t)
              (pt (with-current-buffer source (point))))
          (with-current-buffer preview
            (goto-char (min pt (point-max))))
          (markview--sync-window-state source preview))))))

(defun markview--source-post-command ()
  "Keep preview synchronized with source point."
  (markview--sync-from-buffer (current-buffer)))

(defun markview--preview-post-command ()
  "Mirror preview navigation back to the source buffer."
  (unless markview--syncing
    (let ((source markview-source-buffer))
      (when (buffer-live-p source)
        (let ((pos   (point))
              (start (window-start))
              (markview--syncing t))
          (with-current-buffer source
            (goto-char (min pos (point-max))))
          (let ((sw (get-buffer-window source t))
                (pw (selected-window)))
            (when (and (window-live-p sw) (window-live-p pw))
              (set-window-point sw pos)
              (set-window-start sw start t))))))))

(defun markview--source-after-change (&rest _)
  "Schedule a preview refresh after a source edit."
  (let ((preview markview-preview-buffer))
    (when (buffer-live-p preview)
      (with-current-buffer preview
        (markview--schedule-preview-refresh)))))

(defun markview--schedule-preview-refresh ()
  "Schedule a debounced `markview-refresh'."
  (when markview-preview-mode
    (when markview--refresh-timer
      (cancel-timer markview--refresh-timer))
    (setq markview--refresh-timer
          (run-with-idle-timer
           markview-refresh-delay nil
           (lambda (buf)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (setq markview--refresh-timer nil)
                 (when markview-preview-mode
                   (markview-refresh)))))
           (current-buffer)))))

(defun markview--remove-source-hooks ()
  "Remove all Markview hooks from the current (source) buffer."
  (remove-hook 'post-command-hook #'markview--source-post-command t)
  (remove-hook 'after-change-functions #'markview--source-after-change t)
  (remove-hook 'kill-buffer-hook #'markview-close t))

(defun markview--cleanup-preview ()
  "Clean up links when either side is killed."
  (let ((source  markview-source-buffer)
        (preview markview-preview-buffer))
    (cond
     ((buffer-live-p source)
      (with-current-buffer source
        (setq markview-preview-buffer nil)
        (markview--remove-source-hooks)))
     ((buffer-live-p preview)
      (with-current-buffer preview
        (setq markview-source-buffer nil))))))

;;; ── Commands & mode ───────────────────────────────────────────────────────

(defun markview--heading-slug (text)
  "Convert heading TEXT to a GitHub-style anchor slug.
Downcase, strip non-alphanumeric (except hyphens/spaces), replace spaces
with hyphens."
  (let ((s (downcase (string-trim text))))
    (setq s (replace-regexp-in-string "[^a-z0-9 -]" "" s))
    (replace-regexp-in-string " +" "-" s)))

(defun markview--collect-heading-slugs ()
  "Return an alist of (SLUG . NODE-START) for all headings.
Duplicate slugs get GitHub-style suffixes (-1, -2, etc.)."
  (let ((parser (markview--ensure-parser))
        (counts (make-hash-table :test 'equal))
        result)
    (when parser
      (cl-labels
          ((walk (node)
             (let ((type (treesit-node-type node)))
               (when (member type '("atx_heading" "setext_heading"))
                 (let* ((text (markview--node-text node))
                        (base (markview--heading-slug text))
                        (n (gethash base counts 0))
                        (slug (if (= n 0) base (format "%s-%d" base n))))
                   (puthash base (1+ n) counts)
                   (push (cons slug (treesit-node-start node)) result)))
               (dolist (child (treesit-node-children node t))
                 (walk child)))))
        (walk (treesit-parser-root-node parser))))
    (nreverse result)))

(defun markview--goto-anchor (anchor)
  "Jump to the heading matching ANCHOR in the current buffer.
Returns non-nil on success."
  (let* ((target (downcase anchor))
         (pos (cdr (assoc target (markview--collect-heading-slugs)))))
    (when pos
      (goto-char pos)
      (recenter)
      t)))

(defun markview-open-link-at-point ()
  "Open the link at point in the preview buffer.
Anchor links (#heading) jump to the matching heading in-buffer.
Other URLs are opened with `browse-url'."
  (interactive)
  (let ((url (cl-loop for ov in (overlays-at (point))
                      for v = (overlay-get ov 'markview-link-url)
                      when v return v)))
    (when url
      (if (string-prefix-p "#" url)
          (or (markview--goto-anchor (substring url 1))
              (message "Heading not found: %s" url))
        (browse-url url)))))

(defun markview-open-link-at-mouse (event)
  "Open the link clicked by mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (markview-open-link-at-point))

(defun markview-close ()
  "Close the preview associated with the current buffer."
  (interactive)
  (let* ((source  (or markview-source-buffer (current-buffer)))
         (preview (if markview-source-buffer
                      (current-buffer)
                    markview-preview-buffer)))
    (when (buffer-live-p source)
      (with-current-buffer source
        (markview--remove-source-hooks)
        (setq markview-preview-buffer nil)))
    (when (buffer-live-p preview)
      (let ((win (get-buffer-window preview t)))
        (cond
         ((and (window-live-p win)
               (buffer-live-p source)
               (eq win (frame-root-window)))
          (set-window-buffer win source))
         ((window-live-p win)
          (delete-window win))))
      (with-current-buffer preview
        (remove-hook 'post-command-hook #'markview--preview-post-command t)
        (remove-hook 'kill-buffer-hook #'markview--cleanup-preview t)
        (remove-hook 'kill-buffer-hook #'markview-close t)
        (markview-preview-mode -1))
      (kill-buffer preview))))

(defun markview-open ()
  "Open a synchronized read-only preview for the current Markdown buffer."
  (interactive)
  (unless (treesit-language-available-p 'markdown)
    (user-error
     "Tree-sitter `markdown' grammar not found; install with M-x treesit-install-language-grammar"))
  (let* ((source   (current-buffer))
         (existing markview-preview-buffer))
    (if (buffer-live-p existing)
        (progn
          (display-buffer existing)
          (markview--sync-from-buffer source)
          existing)
      (let* ((preview (clone-indirect-buffer
                       (markview--preview-buffer-name source) nil t))
             (window  (display-buffer
                       preview
                       `((display-buffer-in-direction)
                         (direction . right)
                         (window-width . ,markview-window-size)))))
        (setq markview-preview-buffer preview)
        (with-current-buffer preview
          (setq markview-source-buffer source)
          (setq buffer-read-only t)
          ;; Remove any inherited source hooks
          (markview--remove-source-hooks)
          ;; Install preview hooks
          (add-hook 'post-command-hook #'markview--preview-post-command nil t)
          (add-hook 'kill-buffer-hook #'markview--cleanup-preview nil t)
          (markview-preview-mode 1))
        (with-current-buffer source
          (add-hook 'post-command-hook #'markview--source-post-command nil t)
          (add-hook 'after-change-functions #'markview--source-after-change nil t)
          (add-hook 'kill-buffer-hook #'markview-close nil t))
        (markview--sync-from-buffer source)
        preview))))

(defun markview-toggle ()
  "Toggle the preview for the current buffer."
  (interactive)
  (if (or markview-preview-buffer markview-source-buffer)
      (markview-close)
    (markview-open)))

(provide 'markview)

;;; markview.el ends here
