;;; ethan-wspace.el
;;; Whitespace customizations.
;;
;; For more information on the design of this package, please see the
;; README that came with it.
;;
;; Editing whitespace. I don't like to forcibly clean[1] whitespace
;; because when doing diffs/checkins, it pollutes changesets. However,
;; I prefer clean whitespace -- often I've deleted whitespace by
;; accident and been unable to "put it back" for purposes of diffing.
;;
;; Therefore, my approach is hybrid -- maintain clean whitespace where
;; possible, and avoid disturbing messy whitespce when I come across
;; it. I add a find-file-hook to track whether the whitespace of a
;; given file was clean to begin with, and add a before-save-hook that
;; uses this information to forcibly clean whitespace only if it was
;; clean at start.
;;
;; Viewing whitespace. Originally I had a font-lock-mode hook that
;; always called show-trailing-whitespace and show-tabs, but this
;; turns out to be annoying for a lot of reasons. Emacs internal
;; buffers like *Completions* and *Shell* would get highlit. So I
;; decided that a more sophisticated approach was called for.
;;
;; 1) If a buffer does not correspond to a file, I almost certainly do
;; not care whether the whitespace is clean. I'm not going to be
;; saving it, after all.
;;
;; 2) If a buffer corresponds to a file that was originally clean, I
;; still don't really care about the whitespace, since my hook (above)
;; would ensure that it was clean going forward.
;;
;; 3) If a buffer corresponds to a file that was not originally clean,
;; I do care about seeing whitespace, because I do not want to edit it
;; by accident.
;;
;; There are a few exceptions -- if I'm looking at a patch, or hacking
;; a Makefile, whitespace is different. More about those later.
;;
;; This file adds hooks to make this stuff happen -- check whether the
;; whitespace is clean when a file is first found, and preserve that
;; cleanliness if so, and highlight that dirtiness if not. It does
;; this by setting show-trailing-whitespace when necessary.
;;
;; NOTE: take out any customizations like this:
;; '(show-trailing-whitespace t)
;; show-trailing-whitespace will be turned on by ethan-wspace.
;;
;; Also disable '(require-final-newlines t); ethan-wspace will handle
;; the final newlines.
;;
;; FIXME: Coding conventions suggest using (define-* thing-name) for generated stuff.
;;
;; FIXME: function to clean-ws the whole file and activate all clean-modes?
;;
;; FIXME: fancy lighter
;;
;; FIXME: buffer-local-ize ethan-wspace-errors
;;
;; FIXME: coding conventions suggest adding a ethan-wspace-unload-hook to unhook


;; This variable isn't used. FIXME: provide a function that returns
;; this as a list, for use in customizations.

;; (defvar ethan-wspace-buffer-errors nil
;; "Keep track, per-buffer, which whitespace errors a file has.

;; For possible values, see ethan-wspace-errors.")
;; (make-variable-buffer-local 'ethan-wspace-buffer-errors)

;; This variable isn't used. FIXME: provide a function that does this?

;; (defvar ethan-wspace-builtin-errors '(tabs trailing trailing-newline)
;;   "The list of errors that are recognized by default.")

(defvar ethan-wspace-errors '(tabs eol) ;;; '(tabs trailing trailing-newline)
  "The list of errors that a user wants recognized.

FIXME: This variable should be customizable.")

(defface ethan-wspace-face
  '((t (:background "red")))
  "FIXME: compute this from color-theme or something")


;; Need to set up something like yas/global-mode, which turns on/off
;; ethan-wspace globally

;; Each type of whitespace has:
;; - a find function, which when run, returns (begin end) of the next instance
;;   of this whitespace (or nil if none)
;; - a clean function, which is run to eliminate this kind of whitespace.
;; - a highlight function, which is run with one argument -- 1 to turn
;;   it on, -1 to turn it off. This is probably be a minor mode.
;; FIXME: change to define-ethan-wspace-type?
(defmacro ethan-wspace-declare-type (name &rest args)
  "Declare a whitespace type.

Options recognized: :find :clean :highlight :description
:description is used in docstrings and should be plural."

   (let* ((name-str (symbol-name name))
        (clean-mode-name (concat "ethan-wspace-clean-" name-str "-mode"))
        (clean-mode (intern clean-mode-name))
        (highlight-mode-name (concat "ethan-wspace-highlight-" name-str "-mode"))
        (highlight-mode (intern highlight-mode-name))
        (description (or (plist-get args :description)
                         name-str)))
  `(progn
     (setq ethan-wspace-types (cons (ethan-wspace-make-type ',name ',args) ethan-wspace-types))
     (define-minor-mode ,clean-mode
       ,(format "Verify that %s are clean in this buffer.

Works as a save-file hook that cleans %s.
Turning this mode on turns off highlighting %s, and vice versa." description description description)
       :init-value nil :lighter nil :keymap nil
       ;; FIXME: Body goes here
)


     ,(let ((disable-highlight (intern (concat clean-mode-name "-disable-highlight")))
            (disable-clean     (intern (concat highlight-mode-name "-disable-clean"))))
        ;; Defining these as symbols so that multiple loads don't
        ;; add multiple functions
        `(progn
           (defun ,disable-highlight ()
             (when ,clean-mode (,highlight-mode -1)))
           (defun ,disable-clean ()
             (when ,highlight-mode (,clean-mode -1)))
           (add-hook ',(intern (concat clean-mode-name "-hook"))
                     ',disable-highlight)
           (add-hook ',(intern (concat highlight-mode-name "-hook"))
                     ',disable-clean)))
   )
))

;; We store the whitespace types here.
;; Currently each whitespace type is represented as an association list
;; with keys :check, :clean, and :highlight, and values symbols of functions
;; or whatever.
(defvar ethan-wspace-types nil
  "The list of all known whitespace types.")

;; Define the format/structure for the each wspace type. Right now it's
;; (name . (:foo bar :baz quux)), aka (name :foo bar :baz :quux).
(defun ethan-wspace-make-type (name args)
  (cons name args))

(defun ethan-wspace-get-type (name)
  (or (assq name ethan-wspace-types)
      (error "Ethan Wspace Type '%s' does not exist" name)))

(defun ethan-wspace-type-get-field (type field)
  (plist-get (cdr type) field))

(defun ethan-wspace-type-find (type-or-name)
  "Call the find function for wspace type `type-or-name'.

Type can be either the symbol name of the type, or the type
object itself."
  (let* ((type (if (symbolp type-or-name)
                   (ethan-wspace-get-type type-or-name)
                 type-or-name))
         (find-func (ethan-wspace-type-get-field type :find)))
    (apply find-func nil)))

(defun ethan-wspace-type-check (type-or-name)
  "Check for any instance of this wspace type at all.

Returns t or nil."
  (when (ethan-wspace-type-find type-or-name) t))

(defun ethan-wspace-type-clean (type-or-name &optional begin end)
  "Calls the clean function for wspace type `type-or-name'.

Optional `begin' and `end' are the range to clean.
If absent, use the whole buffer."
  (let* ((type (if (symbolp type-or-name)
                  (ethan-wspace-get-type type-or-name)
                type-or-name))
         (clean-func (ethan-wspace-type-get-field type :clean))
         (real-begin (or begin (point-min)))
         (real-end (or end (point-max))))
    (apply clean-func (list real-begin real-end))))


(defun ethan-wspace-type-activate (type-name)
  "Turn \"on\" the whitespace type given by `type-name'.

If the whitespace for this type is clean, turn on the clean-mode
for this type. Otherwise, turn on the highlight mode for this
type."
  (if (ethan-wspace-type-check type-name)
     (ethan-wspace-type-activate-highlight type-name)
    (ethan-wspace-type-activate-clean type-name)))

(defun ethan-wspace-type-activate-clean (type-name)
  ;;; FIXME: robust against non-stringy type-name?
  ;;; FIXME: refactor with combined activate-highlight?
  (let* ((name-str (if (symbolp type-name) (symbol-name type-name) type-name))
         (clean-mode-name (concat "ethan-wspace-clean-" name-str "-mode"))
         (clean-mode (intern clean-mode-name)))
    (apply clean-mode '(1))))

(defun ethan-wspace-type-clean-mode-active (type-name)
  (let* ((name-str (if (symbolp type-name) (symbol-name type-name) type-name))
         (clean-mode-name (concat "ethan-wspace-clean-" name-str "-mode"))
         (clean-mode (intern clean-mode-name))
         (clean-mode-active (eval clean-mode)))
    clean-mode-active))

(defun ethan-wspace-type-activate-highlight (type-name)
  ;; FIXME: this needs to get the highlight function from the type definition.
  (let* ((name-str (if (symbolp type-name) (symbol-name type-name) type-name))
         (highlight-mode-name (concat "ethan-wspace-highlight-" name-str "-mode"))
         (highlight-mode (intern highlight-mode-name)))
    (apply highlight-mode '(1))))


;;; TABS
(defvar ethan-wspace-type-tabs-regexp "\t+"
  "The regexp to use when searching for tabs.")

(defun ethan-wspace-type-tabs-find ()
  (save-excursion
    (goto-char (point-min))
    (let ((pos (re-search-forward ethan-wspace-type-tabs-regexp nil t)))
      (when pos (cons (match-beginning 0) (match-end 0))))))

(defun ethan-wspace-untabify (start end)
  "Like `untabify', but be more respectful of point.
The standard `untabify' does not keep track of point when
deleting tabs and replacing with spaces. This means point can
jump to the beginning of a tab if it was at the end of a tab when
untabify was called.

Since we clean tabs implicitly, we don't want point to jump around.
For details on how we accomplish this, see the source."
  ;; Stock untabify does three things that cause this problem together:
  ;;
  ;; 1. untabify deletes tabs before inserting spaces, which collapses
  ;;    the point-before-tabs and point-after-tabs cases.
  ;;
  ;; 2. save-excursion saves position of point using a marker, but
  ;;    since the insertion type of that marker is nil, inserting
  ;;    spaces before the marker don't move the marker. This is fine
  ;;    when point-before-tabs but wrong when point-after-tabs.  (We
  ;;    use insert-before-markers instead of indent-to-column to
  ;;    handle this.)
  ;;
  ;; 3. Point could be between two tabs, but untabify replaces
  ;;    multiple tabs at once, which is guaranteed to give you the
  ;;    wrong result.
  (interactive "r")
  (save-excursion
    (save-restriction
      (narrow-to-region (point-min) end)
      (goto-char start)
      (while (search-forward "\t" nil t)        ; faster than re-search
        (forward-char -1)
        (let ((tab-start (point))
              (column-start (current-column)))
          (forward-char 1)
          (let ((column-end (current-column)))
            ;; Insert text after tabs, but before markers, so that
            ;; point-marker (if after tab) will be advanced.
            (insert-before-markers (make-string (- column-end column-start) ?\ ))
            ;; Delete tabs, so we can handle before-tabs and after-tabs
            ;; separately.
            (delete-region tab-start (1+ tab-start))))))))

(defvar ethan-wspace-type-tabs-keyword
  (list ethan-wspace-type-tabs-regexp 0 (list 'quote 'ethan-wspace-face) t)
  "The font-lock keyword used to highlight tabs.")

(define-minor-mode ethan-wspace-highlight-tabs-mode
  "Minor mode to highlight tabs.

With arg, turn tab-highlighting on if arg is positive, off otherwise.
This supercedes (require 'show-wspace) and show-ws-highlight-tabs."
  :init-value nil :lighter nil :keymap nil
  (if ethan-wspace-highlight-tabs-mode
      (font-lock-add-keywords nil (list ethan-wspace-type-tabs-keyword))
    (font-lock-remove-keywords nil (list ethan-wspace-type-tabs-keyword)))
  (font-lock-fontify-buffer))

(ethan-wspace-declare-type tabs :find ethan-wspace-type-tabs-find
                           :clean ethan-wspace-untabify :highlight ethan-wspace-highlight-tabs-mode
                           )


;; Trailing whitespace on each line: symbol `eol', lighter L.  Named
;; "eol" to distinguish from final-newline whitespace (ensuring that
;; there is exactly one newline at EOF).
(defvar ethan-wspace-type-eol-regexp "\\s-+$"
  "The regexp to use to find end-of-line whitespace.")

(defun ethan-wspace-type-eol-find ()
  (save-excursion
    (goto-char (point-min))
    (let ((pos (re-search-forward ethan-wspace-type-eol-regexp nil t)))
      (when pos (cons (match-beginning 0) (match-end 0))))))

;;; Implemented using show-trailing-whitespace.
;;;
;;; emacs core handles show-trailing-whitespace specially. It's
;;; impossible (AFAICT) to use font-lock keywords to highlight
;;; trailing whitespace except when point is right afterwards, so we
;;; just use show-trailing-whitespace.
(define-minor-mode ethan-wspace-highlight-eol-mode
  "Minor mode to highlight trailing whitespace.

With arg, turn highlighting on if arg is positive, off otherwise.
This internally uses `show-trailing-whitespace'."
  :init-value nil :lighter nil :keymap nil
  (setq show-trailing-whitespace ethan-wspace-highlight-eol-mode))

(defun ethan-wspace-type-eol-clean (begin end)
  (save-restriction
    (narrow-to-region begin end)
    (delete-trailing-whitespace)))

(ethan-wspace-declare-type eol :find ethan-wspace-type-eol-find
                           :clean ethan-wspace-type-eol-clean
                           :highlight ethan-wspace-highlight-eol-mode)

;; show-trailing-whitespace uses the face `trailing-whitespace', so we
;; make this mirror `ethan-wspace-face'.
(copy-face 'ethan-wspace-face 'trailing-whitespace)


;;; End-of-file newlines: symbol `trailing-newline'
(defun ethan-wspace-count-trailing-nls ()
  (save-excursion
    (goto-char (point-max))
    (skip-chars-backward "\n")
    (- (point-max) (point))))

(defun ethan-wspace-type-trailing-nls-find ()
  (let* ((trailing-newlines (ethan-wspace-count-trailing-nls))
         (max (point-max)))
    (if (= trailing-newlines 1)
        nil
      (if (= trailing-newlines 0)
          (cons max max)
        (cons (- max (1- trailing-newlines)) max)))))

;;; This is a failed attempt at using a font-lock keyword to look for
;;; trailing newlines.  It doesn't work because there's no regexp that
;;; matches EOF. I'm keeping it here in case I want to use the
;;; define-ethan-wspace-highlight-mode macro.

;; (defvar ethan-wspace-type-trailing-newline-keyword
;;   (list ethan-wspace-type-trailing-newline-regexp 0 (list 'quote 'ethan-wspace-face) t)
;;   "The font-lock keyword used to highlight trailing newlines.")

;; (defmacro define-ethan-wspace-highlight-mode (name doc &rest args)
;;   (let ((font-lock-keyword (plist-get args :font-lock-keyword)))
;;     (unless font-lock-keyword
;;       (error "Font-lock keyword sucked somehow: %s" args))

;;     `(define-minor-mode ,name ,doc
;;        :init-value nil :lighter nil :keymap nil
;;        (if ,name
;;            (font-lock-add-keywords nil (list ,font-lock-keyword))
;;          (font-lock-remove-keywords nil (list ,font-lock-keyword)))
;;        (font-lock-fontify-buffer))))

;; (define-ethan-wspace-highlight-mode ethan-wspace-highlight-trailing-newlines-mode
;;   "Minor mode to highlight trailing newlines if absent or if more than 1.

;; With arg, turn highlighting on if arg is positive, off otherwise."
;;   :font-lock-keyword ethan-wspace-type-trailing-newline-keyword)


;; Implemented using overlays to mark a fake "eof" string, or
;; highlight newlines at end of file.  I couldn't figure out a way to
;; make the eof have a trailing newline AND keep the cursor on the
;; first character -- putting a \n in the overlay seems to force the
;; cursor to the newline afterwards -- so I just extend the overlay to
;; edge-of-frame manually. This kind of sucks but it'll hopefully do
;; for now.
(define-minor-mode ethan-wspace-highlight-trailing-nls-mode
  "Minor mode to highlight trailing newlines if absent or if more than 1.

With arg, turn highlighting on if arg is positive, off otherwise."
  :init-value nil :lighter nil :keymap nil
  (if ethan-wspace-highlight-trailing-nls-mode
      (progn
        (ethan-wspace-highlight-trailing-nls-make-overlay)
        (add-hook 'pre-command-hook 'ethan-wspace-highlight-trailing-nls-pre-command-hook nil t)
        (add-hook 'post-command-hook 'ethan-wspace-highlight-trailing-nls-post-command-hook nil t))
    (remove-hook 'pre-command-hook  'ethan-wspace-highlight-trailing-nls-pre-command-hook t)
    (remove-hook 'post-command-hook 'ethan-wspace-highlight-trailing-nls-post-command-hook t)))

(defvar ethan-wspace-highlight-trailing-nls-overlay nil
  "An overlay used to indicate that trailing newlines are missing or to highlight.")

(make-variable-buffer-local 'ethan-wspace-highlight-trailing-nls-overlay)

(defun ethan-wspace-highlight-trailing-nls-make-overlay ()
  (setq ethan-wspace-highlight-trailing-nls-overlay (make-overlay 0 0)))

(defun ethan-wspace-highlight-trailing-nls-update-overlay-off ()
  (overlay-put ethan-wspace-highlight-trailing-nls-overlay 'after-string nil)
  (overlay-put ethan-wspace-highlight-trailing-nls-overlay 'face nil))

(defun ethan-wspace-highlight-trailing-nls-update-overlay-missing ()
  "Update the overlay to show that there is no trailing newline at end of file."
  (ethan-wspace-highlight-trailing-nls-update-overlay-off)
  (save-excursion
    (move-overlay ethan-wspace-highlight-trailing-nls-overlay (point-max) (point-max))
    (goto-char (point-max))
    (let* ((str-len (- (frame-width) (current-column)))
           (str (concat "eof" (make-string (- str-len 3) ?\ ))))
      (set-text-properties 0 str-len '(face ethan-wspace-face) str)
      (set-text-properties 0 1 '(cursor t face ethan-wspace-face) str)
      (overlay-put ethan-wspace-highlight-trailing-nls-overlay 'after-string str))))

(defun ethan-wspace-highlight-trailing-nls-update-overlay-too-many ()
  "Update the overlay to highlight the newlines at EOF."
  (ethan-wspace-highlight-trailing-nls-update-overlay-off)
  (save-excursion
    (goto-char (point-max))             ; end of file
    (skip-chars-backward "\n")          ; backwards through all of them
    (forward-char 1)                      ; leave one, which is the correct amount
    (move-overlay ethan-wspace-highlight-trailing-nls-overlay (point) (point-max))
    (overlay-put ethan-wspace-highlight-trailing-nls-overlay 'face 'ethan-wspace-face)))

(defun ethan-wspace-highlight-trailing-nls-pre-command-hook ()
  ;; For some reason vline uses this to turn off the overlay.
  ;; Probably for ease of creating new overlays without having to
  ;; delete old ones?  No idea, but I'm just copying what they do,
  ;; so..
  ())

(defun ethan-wspace-highlight-trailing-nls-post-command-hook ()
  (let ((trailing-nls (ethan-wspace-count-trailing-nls)))
    (cond
     ((= trailing-nls 0)
      (ethan-wspace-highlight-trailing-nls-update-overlay-missing))
     ((> trailing-nls 1)
      (ethan-wspace-highlight-trailing-nls-update-overlay-too-many))
     (t
      (ethan-wspace-highlight-trailing-nls-update-overlay-off)))))

;;; ethan-wspace-mode: doing stuff for all types.
(define-minor-mode ethan-wspace-mode
  "Minor mode for coping with whitespace.

This just activates each whitespace type in this buffer."
  :init-value nil :lighter nil :keymap nil
  ;(message "Turning on ethan-wspace mode for %s" (buffer-file-name))
  (dolist (type ethan-wspace-errors)
    (ethan-wspace-type-activate type)))

(defun ethan-wspace-is-buffer-appropriate ()
  ;;; FIXME: not OK for diff mode, non-file modes, etc?
  (when (buffer-file-name)
    (ethan-wspace-mode 1)))

(define-global-minor-mode global-ethan-wspace-mode
  ethan-wspace-mode ethan-wspace-is-buffer-appropriate
  :init-value t)

(defun ethan-wspace-clean-before-save-hook ()
  (when ethan-wspace-mode
    (dolist (type ethan-wspace-errors)
      (when (ethan-wspace-type-clean-mode-active type)
          (ethan-wspace-type-clean type)))))

(add-hook 'before-save-hook 'ethan-wspace-clean-before-save-hook)

;;; Showing whitespace
;;
;; We want to show whitespace if it's a real file and the original ws
;; was broken. If it was clean originally, we assume it'll be correct
;; (we'll clean it every save anyhow).
;;
;; We also turn it off for real files with dont-show-ws-this-buffer set to t.
;; Thus for .patch or .diff files, we can use special diff-mode magic.
(defvar dont-show-ws-this-buffer nil)
(make-variable-buffer-local 'dont-show-ws-this-buffer)

;; (require 'show-wspace)
;; (add-hook 'font-lock-mode-hook
;;           (lambda ()
;;             (if (and (buffer-file-name)
;;                      (not dont-show-ws-this-buffer)
;;                      (not (buffer-whitespace-clean-p)))
;;                 (progn
;;                   (show-ws-highlight-tabs)
;;                   (setq show-trailing-whitespace t)))))

(defun dont-show-ws ()
;  (setq show-trailing-whitespace nil)  ; I have this variable customized
  (setq dont-show-ws-this-buffer t))

(add-hook 'diff-mode-hook 'dont-show-ws)

;; Diff mode.
;;
;; Every line in a diff starts with a plus, a minus, or a space -- so
;; empty lines in common with both files will show up as lines with
;; just a space in the diff. As a result, we only highlight trailing
;; whitespace for non-empty lines.
;;
;; The regex matches whitespace that only comes at
;; the end of a line with non-space in it.
;;
; FIXME: This also makes the diff-mode font lock break a little --
; changes text color on lines that match.
;
; FIXME: "bzr diff" format contains tabs?
(add-hook 'diff-mode-hook
          (lambda ()
            (font-lock-add-keywords nil
                                    '(("\\S-\\([\240\040\t]+\\)$"
                                       (1 'show-ws-trailing-whitespace t))))))


; FIXME: compute this color based on the current color-theme
;(setq space-color "#562626")
;(set-face-background 'show-ws-tab space-color)
; FIXME: show-ws-trailing-whitespace should be strongly deprecated!
;(set-face-background 'show-ws-trailing-whitespace space-color)
;(set-face-background 'trailing-whitespace space-color)

(provide 'ethan-wspace)
