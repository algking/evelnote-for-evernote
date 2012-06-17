;;; evelnote.el --- sync evernote note with emacs buffer
(defvar evelnote-version-number "0.0.1")
;; Copyright (C) 2012  hadashiA

;; Author: hadashiA <dev@hadashikick.jp>
;; Keywords: 

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; development now

;;; Code:

(eval-when-compile (require 'cl))

;; custom

(defgroup evelnote nil
  "evelnote.el is an emacs package for interfacing with Evernote (http://www.evernote.com)"
  :version evelnote-version-number
  :group 'evelnote)

(defcustom evelnote-username
  ""
  "Your Evernote username"
  :group 'evelnote
  :type 'string)

(defcustom evelnote-password
  ""
  "Your Evernote password."
  :group 'evelnote
  :type 'string)

(defcustom evelnote-notelist-per-page
  100
  "number of notes to be loaded at a time"
  :group 'evelnote
  :type 'integer)

(defcustom evelnote-notelist-initial-queries
  nil
  ""
  :group 'evelnote
  :type 'sexp
  )

(defcustom evelnote-cache-directory
  (expand-file-name (concat (file-name-directory (or load-file-name
                                                     buffer-file-name))
                            "cache"))
  "Path of note content cache directory")

(defconst evelnote-note-guid-regexp "\\w\\{8\\}-\\(\\w\\{4\\}-\\)\\{3\\}\\w\\{12\\}"
  "note guid REGEXP")

(defconst evelnote-timeout-seconds 15 "timeout sec" )

(defconst evelnote-edam-buffer-name "*Evernote API*")

(defvar evelnote-edam-process nil)

(defvar evelnote-command
  "evelnote"
  "Path of api script")

(defvar evelnote-coding-system 'utf-8)

(defvar evelnote-search-history nil)
(defvar evelnote-notebook-name-history nil)

(defvar evelnote-default-notebook nil)
(defvar evelnote-notebook-list nil)

(defvar evelnote-notelist-buffer-list nil
  "List of buffers managed by `evelnote-notelist-mode'.")

(defvar evelnote-html-modes '(html-mode html-helper-mode psgml-mode))
(defvar evelnote-markdown-modes '(fundamental-mode text-mode markdown-mode default-generic-mode))

(defvar evelnote-note-buffers (make-hash-table :test #'equal :size 100))
(defvar evelnote-save-note-queue nil)

(defvar evelnote-note nil)
(make-variable-buffer-local 'evelnote-note)
(make-variable-buffer-local 'evelnote-from-notelist-buffer)

;; 
;; struct
;; 

(defstruct evelnote-notebook
  guid
  name
  update-sequence-num
  default-notebook
  service-created
  service-updated
  publishing
  published
  stack
  shared-notebook-ids
  )

(defstruct evelnote-notelist
  start-index
  total-notes
  notes
  stopped-words
  searched-words
  update-count
  )

(defstruct evelnote-note
  guid
  title
  content
  content-hash
  content-length
  created
  updated
  deleted
  active
  update-sequence-num
  notebook-guid
  tag-guids
  resources
  attributes
  tag-names
  )

(defstruct evelnote-tag
  guid
  name
  parent-guid
  update-sequence-num
  )

(defstruct evelnote-resource
  guid
  note-guid
  data
  mime
  width
  height
  duration
  active
  recognition
  attributes
  update-sequence-num
  alternate-data
  )

(defstruct evelnote-data
  body-hash
  size
  body
  )

(defstruct evelnote-resource-attributes
  source-url
  timestamp
  latitude
  longitude
  altitude
  camera-make
  camera-model
  client-will-index
  reco-type
  file-name
  attachment
  application-data
  )

(defstruct evelnote-note-attributes
  subject-date
  latitude
  longitude
  altitude
  author
  source
  source-url
  source-application
  share-date
  task-date
  task-complete-date
  task-due-date
  place-name
  content-class
  application-data
  )

;; 
;; programming tools (http://www.bookshelf.jp/texi/onlisp/onlisp_15.html)
;;

(defmacro evelnote-aif (test-form then-form &rest else-forms)
  "Anaphoric if. Temporary variable `it' is the result of test-form."
  `(let ((it ,test-form))
     (if it ,then-form ,@else-forms)))
(put #'evelnote-aif 'lisp-indent-function 2)

(defmacro evelnote-awhen (test-form &rest body)
  "Anaphoric when."
  (declare (indent 1))
  `(evelnote-aif ,test-form
	(progn ,@body)))

(defmacro evelnote-awhile (expr &rest body)
  "Anaphoric while."
  (declare (indent 1))
  `(do ((it ,expr ,expr))
       ((not it))
     ,@body))

(defmacro evelnote-ablock (tag &rest args)
  "Anaphoric block."
  (declare (indent 1))
  `(block ,tag
     ,(funcall (alambda (args)
			(case (length args)
			  (0 nil)
			  (1 (car args))
			  (t `(let ((it ,(car args)))
				,(self (cdr args))))))
	       args)))

(defmacro evelnote-aand (&rest args)
  "Anaphoric and."
  (declare (indent 1))
  (cond ((null args) t)
	((null (cdr args)) (car args))
	(t `(evelnote-aif ,(car args) (evelnote-aand ,@(cdr args))))))

(defmacro evelnote-acond (&rest clauses)
  (if (null clauses)
      nil
    (let ((cl1 (car clauses))
	  (sym (gensym)))
      `(let ((,sym ,(car cl1)))
	 (if ,sym
	     (let ((it ,sym)) ,@(cdr cl1))
	   (evelnote-acond ,@(cdr clauses)))))))

;; 
;; advice
;;

(defadvice dired-jump (around evelnote-jump-to-notelist (activate))
  (if (and (null buffer-file-name)
           evelnote-from-notelist-buffer
           (bufferp evelnote-from-notelist-buffer)
           (with-current-buffer evelnote-from-notelist-buffer
             (eq major-mode evelnote-notelist-mode)))
      (switch-to-buffer evelnote-from-notelist-buffer)
    ad-do-it))

;; 
;; evelnote-notelist-mode (global)
;;

(defun evelnote-notelist-mode ()
  "Set up the current buffer for `evelnote-notelist-mode'."
  (kill-all-local-variables)
  (setq major-mode 'evelnote-notelist-mode
        mode-name "Evelnote-Notes")

  (unless (memq (current-buffer) (evelnote-notelist-buffer-list-get))
    (add-to-list 'evelnote-notelist-buffer-list (current-buffer)))

  (use-local-map evelnote-notelist-mode-map)
  (run-hooks 'evelnote-notelist-mode-hook)
  (buffer-disable-undo))

(defvar evelnote-notelist-mode-map
  (let ((keymap (make-keymap))
        (key-list '(("j" . evelnote-notelist-goto-next-note)
                    ("k" . evelnote-notelist-goto-previous-note)
                    ("n" . evelnote-notelist-goto-next-note)
                    ("p" . evelnote-notelist-goto-previous-note)
                    ("f" . evelnote-notelist-switch-to-next-buffer)
                    ("b" . evelnote-notelist-switch-to-previous-buffer)

                    ("i" . evelnote-notelist-toggle-metadata)
                    ("I" . evelnote-notelist-toggle-metadata-all)

                    ("\C-i" . evelnote-notelist-tab)
                    
                    ("g" . evelnote-notelist-buffer-reload)
                    ("q" . evelnote-notelist-buffer-kill)
                    ("\C-m" . evelnote-notelist-enter))))
    (dolist (key-info key-list)
      (define-key keymap (car key-info) (cdr key-info)))
    keymap))
(define-key evelnote-notelist-mode-map (kbd "<backtab>") #'evelnote-notelist-backtab)

(defface evelnote-notelist-header
  '((t (:inherit header-line))) 
  "Face for header lines in the evernote notelist buffer.")

(defface evelnote-notelist-notebook-name
  '((t (:inherit dired-header))) 
  "Face Notebook name in the evernote notelist buffer.")

(defface evelnote-notelist-tag-name
  '((t (:inherit dired-directory))) 
  "Face Notebook name in the evernote notelist buffer.")

;; buffer management

(defun evelnote-notelist-buffer-p (&optional buffer)
  "Return t if BUFFER is managed by `evelnote'.
BUFFER defaults to the current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (memq buffer evelnote-notelist-buffer-list))))

(defun evelnote-notelist-buffer-unregister (buffer)
  "Unregister BUFFER from `evelnote-notelist-buffer-list'."
  (when (memq buffer evelnote-notelist-buffer-list)
    (setq evelnote-notelist-buffer-list
          (delq buffer evelnote-notelist-buffer-list))))

(defun evelnote-notelist-buffer-list-get ()
  (dolist (buffer evelnote-notelist-buffer-list)
    (unless (buffer-live-p buffer)
      (evelnote-notelist-buffer-unregister buffer)))
  evelnote-notelist-buffer-list)

(defun evelnote-notelist-buffer-get (query)
  (loop for b in (evelnote-notelist-buffer-list-get)
        when (with-current-buffer b
               (string-equal evelnote-notelist-query query))
        return b))

;; evelnote-notelist-buffer utils

(defun* evelnote-notelist-buffer-position-at (note)
  (let ((pos)))
  (save-excursion
    (goto-char (point-min))
    (while (setq pos (next-single-property-change (point) 'evelnote-note-title))
      (when (equal (evelnote-note-guid note)
                   (evelnote-note-guid (get-text-property pos 'evelnote-note)))
        (return-from evelnote-notelist-buffer-position-at)))))

;; evelnote-notelist methods

(defun evelnote-notelist-render (notelist query)
  (unless (evelnote-notelist-p notelist)
    (error "\"%S\" is invalid as a Evernote note list" notelist))
  (let* ((buffer (or (evelnote-notelist-buffer-get query)
                     (with-current-buffer (generate-new-buffer query)
                       (evelnote-notelist-mode)
                       (current-buffer))))
         (header-end-marker (make-marker))
         (note-start-marker (make-marker))
         (note-metadata-start-marker (make-marker)))

    (with-current-buffer buffer
      (set (make-local-variable 'evelnote-notelist-query) query)
      (set (make-local-variable 'evelnote-notelist) notelist)

      (setq buffer-read-only nil)
      (delete-region (point-min) (point-max))

      (insert (propertize
               (format "Evernote searched:\"%s\" total:%d\n"
                       query
                       (evelnote-notelist-total-notes notelist))
              'face 'evelnote-notelist-header
              'evelnote-notelist-header t))
      (set-marker header-end-marker (point))
      
      (dolist (note (evelnote-notelist-notes notelist))
        (set-marker note-start-marker (point))
        (insert (propertize (evelnote-note-title note)
                            'evelnote-note-title (evelnote-note-title note)))
        (insert "\n")

        (set-marker note-metadata-start-marker (point))
        (insert " ")
        (evelnote-awhen (evelnote-aand (evelnote-note-notebook note)
                                       (evelnote-notebook-name it))
          (insert (propertize (format "%s" it)
                              'face 'evelnote-notelist-notebook-name
                              'evelnote-notebook-name it))
          (insert (propertize " "
                              'face 'evelnote-notelist-tag-name)))
        (insert
         (mapconcat (lambda (tag-name)
                      (propertize tag-name
                                  'face evelnote-notelist-tag-name
                                  'evelnote-tag-name tag-name))
                    (evelnote-note-tag-names note)
                    ", "))
        (insert "\n\n")

        (put-text-property (marker-position note-metadata-start-marker)
                           (point) 'invisible (evelnote-note-guid note))
        (put-text-property (marker-position note-start-marker)
                           (point) 'evelnote-note note)
        (add-to-invisibility-spec (evelnote-note-guid note)))

      (setq buffer-read-only t)
      (goto-char (marker-position header-end-marker)))
    buffer))

;; evelnote-notelist-mode commands

(defun evelnote-notelist-goto-next-note ()
  (interactive)
  (evelnote-awhen (next-single-property-change (point) 'evelnote-note)
    (goto-char it))
  (back-to-indentation))

(defun evelnote-notelist-goto-previous-note ()
  (interactive)
  (evelnote-awhen (previous-single-property-change (point) 'evelnote-note)
    (goto-char it))
  (back-to-indentation))

(defun* evelnote-notelist-goto-next-thing ()
  (interactive)
  (let ((next-change (point)))
    (while (setq next-change (next-property-change next-change))
      (when (loop for property-name in '(evelnote-note-title
                                         evelnote-notebook-name
                                         evelnote-tag-name)
                  thereis (get-text-property next-change property-name))
        (goto-char next-change)
        (return-from evelnote-notelist-tab)))))

(defun* evelnote-notelist-goto-previous-thing ()
  (interactive)
  (let ((previous-change (point)))
    (while (setq previous-change (previous-property-change previous-change))
      (when (loop for property-name in '(evelnote-note-title
                                         evelnote-notebook-name
                                         evelnote-tag-name)
                  thereis (get-text-property previous-change property-name))
        (goto-char previous-change)
        (return-from evelnote-notelist-backtab)))))

(defun evelnote-notelist-switch-to-next-buffer ()
  (interactive)
  (when (evelnote-notelist-buffer-p)
    (let* ((buffer-list (evelnote-notelist-buffer-list-get))
           (following-buffers (cdr (memq (current-buffer) buffer-list)))
           (next (if following-buffers
                     (car following-buffers)
                   (car buffer-list))))
      (unless (eq (current-buffer) next)
        (switch-to-buffer next)))))

(defun evelnote-notelist-switch-to-previous-buffer ()
  (interactive)
  (when (evelnote-notelist-buffer-p)
    (let* ((buffer-list (reverse (evelnote-notelist-buffer-list-get)))
           (preceding-buffers (cdr (memq (current-buffer) buffer-list)))
           (previous (if preceding-buffers
                         (car preceding-buffers)
                       (car buffer-list))))
      (unless (eq (current-buffer) previous)
        (switch-to-buffer previous)))))

(defun evelnote-notelist-buffer-kill (&optional buffer)
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (when (evelnote-notelist-buffer-p buffer)
      (kill-buffer buffer)
      (evelnote-notelist-buffer-unregister buffer))))

(defun evelnote-notelist-buffer-reload (&optional buffer)
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (when (evelnote-notelist-buffer-p buffer)
      (evelnote-search evelnote-notelist-query))))

(defun evelnote-notelist-toggle-metadata ()
  (interactive)
  (evelnote-awhen (evelnote-aand (get-text-property (point) 'evelnote-note)
                                 (evelnote-note-guid it))
    (if (loop for note-guid in buffer-invisibility-spec
              thereis (equal note-guid it))
        (remove-from-invisibility-spec it)
      (add-to-invisibility-spec it))
    (redraw-display))
  (unless (get-text-property (point) 'evelnote-note-title)
    (evelnote-notelist-goto-previous-note)))

(defun evelnote-notelist-toggle-metadata-all ()
  (interactive)
  (setq buffer-invisibility-spec
        (if buffer-invisibility-spec
            nil
          (loop for note in (evelnote-notelist-notes evelnote-notelist)
                collect (evelnote-note-guid note))))
  (redraw-display)
  (unless (get-text-property (point) 'evelnote-note-title)
    (evelnote-notelist-goto-previous-note)))
  

(defun evelnote-notelist-enter ()
  (interactive)
  (evelnote-acond
   ((get-text-property (point) 'evelnote-notebook-name)
    (evelnote-search (format "notebook:%s" it)))
   ((get-text-property (point) 'evelnote-tag-name)
    (evelnote-search (format "tag:%s" it)))
   ((get-text-property (point) 'evelnote-note)
    (evelnote-note-render it (when (eq major-mode 'evelnote-notelist-mode)
                               (current-buffer))))))

;; 
;; evelnote-mode (minor)
;;

(define-minor-mode evelnote-mode
  "Evernote note edit and view."
  :lighter " Evelnote"
  :group 'evelnote

  (if evelnote-mode
      (progn
        (add-hook 'kill-buffer-hook #'evelnote-note-buffer-unregister nil t))
    (setq evelnote-note nil)
    (remove-hook 'kill-buffer-hook #'evelnote-note-buffer-unregister t)
    (evelnote-note-buffer-unregister)))

(defvar evelnote-mode-map (make-sparse-keymap))
(dolist (key-info '(("\C-x\C-s" . evelnote-save-buffer)
                    ("\C-x\C-r" . evelnote-reload)
                    ;; ("\C-x\C-d" . evelnote-jump-to-parent-notelist))
                  )
  (define-key evelnote-mode-map (car key-info) (cdr key-info)))

;; evelnote-note-buffer methods

(defun evelnote-note-buffer-unregister (&optional buffer)
  (with-current-buffer (or buffer (current-buffer))
    (evelnote-aif (evelnote-aand evelnote-mode
                                 (evelnote-note-p evelnote-note)
                                 (evelnote-note-guid evelnote-note))
        (remhash it evelnote-note-buffers))))

;; evelnote-note methods

(defun evelnote-note-notebook (note)
  (let ((notebook-guid (evelnote-note-notebook-guid note)))
    (loop for notebook in (evelnote-notebook-list)
          when (equal notebook-guid (evelnote-notebook-guid notebook))
          return notebook)))

(defun evelnote-note-validate (note &optional require-field-names)
  (when (or (null note)
            (not (evelnote-note-p note)))
    (error "\"%S\" is invalid as a Evernote note" note))
  (dolist (field-name require-field-names)
    (when (null (funcall (intern (format "evelnote-note-%s" field-name)) note))
      (error "invalid note. require field '%s is null" field-name)))
  t)

(defun evelnote-mode-setup (note)
  (evelnote-note-validate note)
  (unless evelnote-mode (evelnote-mode))
  (setq evelnote-note note)
  (setf (gethash (evelnote-note-guid note) evelnote-note-buffers) (current-buffer)))

(defun evelnote-note-render (note &optional from-notelist-buffer)
  (evelnote-note-validate note '(guid))

  (let ((guid (evelnote-note-guid note))
        (content (evelnote-note-content note)))
    (when (null content)
      (setq note (evelnote-send (format "get note %s\n"
                                        (evelnote-note-guid note)))))  
    (evelnote-aif (gethash guid evelnote-note-buffers)
        (switch-to-buffer it)
      (let ((buffer (generate-new-buffer (evelnote-note-title note))))
        (with-current-buffer buffer
          (evelnote-mode-setup note)
          (insert (evelnote-note-content evelnote-note))
          (goto-char (point-min)))
        (switch-to-buffer buffer)))
    (setq evelnote-from-notelist-buffer
          (or from-notelist-buffer evelnote-from-notelist-buffer))))

;; evelnote-mode commands

(defun evelnote-reload ()
  (interactive)
  (when evelnote-mode
    (let* ((local-note evelnote-note)
           (remote-note (evelnote-send
                         (format "get note %s\n"
                                 (evelnote-note-guid local-note)))))
      (unless (string-equal (evelnote-note-content-hash local-note)
                            (evelnote-note-content-hash remote-note))
        (delete-region (point-min) (point-max))
        (insert (evelnote-note-content note))
        (setq evelnote-note note)
        (goto-char (point-min))))))

(defun* evelnote-save-buffer (&optional edit-metadata)
  "save note from current buffer."
  (interactive "p")

  (let ((input-buffer (current-buffer))
        (note (or (and evelnote-mode
                       (evelnote-note-p evelnote-note)
                       evelnote-note)
                  (make-evelnote-note))))

    (evelnote-with-edam-buffer
     (setf (evelnote-note-content note) input-buffer)
     (when (or (null (evelnote-note-guid note)) edit-metadata)
       (setf (evelnote-note-title note)
             (read-string "title: " (cons (evelnote-title-for input-buffer) 0)))
       (setf (evelnote-note-notebook-guid note) (evelnote-read-notebook-guid)
             (evelnote-note-tag-names note) (evelnote-read-tag-names)))
     
     (evelnote-save note))))

(defun evelnote-jump-to-parent-notelist ()
  (when (and evelnote-from-notelist-buffer
             (bufferp evelnote-from-notelist-buffer)
             (with-current-buffer evelnote-from-notelist-buffer
               (eq major-mode 'evelnote-notelist-mode)))
    (switch-to-buffer evelnote-from-notelist-buffer)))

(defun evelnote-jump-to-notelist ()
  (interactive)
  (let ((note evelnote-note))
    (evelnote-aif (loop for notelist-buffer in (evelnote-notelist-buffer-list-get)
                        for note-pos = (with-current-buffer notelist-buffer
                                         (evelnote-notelist-buffer-position-at note))
                        when note-pos
                        return (cons notelist-buffer note-pos))
        (progn
          (switch-to-buffer (car it))
          (goto-char (cdr it)))
      (message "notelist buffer not found."))))

;; 
;; evernote edam interface
;; 

(defun evelnote-start ()
  (if (or (null evelnote-edam-process)
          (not (eq (process-status evelnote-edam-process) 'run)))
      (setq evelnote-edam-process (evelnote-authenticate))
    evelnote-edam-process))

(defmacro evelnote-with-edam-buffer (&rest spec)
  `(block nil
     (when (evelnote-start)
       (with-current-buffer (process-buffer evelnote-edam-process)
         (delete-region (point-min) (point-max))
         (flet ((send (str)
                      (process-send-string evelnote-edam-process str))
                (send-region (start end)
                             (process-send-region evelnote-edam-process start end))
                (send-eof (&optional process-name)
                          (process-send-eof evelnote-edam-process)))
           ,@spec)))))

(defun evelnote-get-response (&optional faild-count)
  (setq faild-count (or faild-count 0))
  (condition-case err
      (with-current-buffer evelnote-edam-buffer-name
        (goto-char (point-min))
        (let ((res (eval (read (current-buffer)))))
          (delete-region (point-min) (point))
          res))

    (end-of-file (incf faild-count)
                 ;; (message "faild-count:%d" faild-count)
                 (when (> faild-count 100)
                   (error "parse error \"%S\"" (buffer-string)))
                 ;; (sleep-for 0.01)
                 (sleep-for 0.05)
                 (evelnote-get-response faild-count)
                 )))

(defun evelnote-wait-and-get-response ()
  (if (accept-process-output evelnote-edam-process evelnote-timeout-seconds)
        (condition-case err
            (evelnote-get-response)
          (error (switch-to-buffer evelnote-edam-buffer-name)
                 (error "Evernote response error:\"%s\" see \"%s\" buffer"
                        (error-message-string err)
                        evelnote-edam-buffer-name)
                 nil))
      (error "Evernote timeout." )))

(defun evelnote-send (command)
  (let ((edam-process)
        (edam-buffer))
    (evelnote-with-edam-buffer
     (setq edam-buffer (current-buffer)
           edam-process (get-buffer-process (current-buffer)))
     (send command))
    (evelnote-wait-and-get-response)))

(defun evelnote-kill ()
  "Kill evernote process"
  (interactive)
  (evelnote-awhen (and evelnote-edam-process
                       (process-buffer evelnote-edam-process))
    (kill-buffer it))
  (when (and evelnote-edam-process
             (eq (process-status evelnote-edam-process) 'run))
    (kill-process evelnote-edam-process))
  (setq evelnote-edam-process nil
        evelnote-username nil
        evelnote-password nil))

(defun evelnote-authenticate ()
  (evelnote-kill)

  (if (> 1 (length evelnote-username))
      (setq evelnote-username (read-string "your Evernote username: ")))
  (if (> 1 (length evelnote-password))
      (setq evelnote-password
	    (read-passwd (format "%s's Evernote password: "
				 evelnote-username))))

  (message "authenticate...")
  (let* ((process (eval `(start-process "evelnote"
                                        evelnote-edam-buffer-name
                                        ,@(split-string evelnote-command)
                                        "-u" evelnote-username
                                        "-p" evelnote-password
                                        ))))

    (when (fboundp 'set-process-coding-system)
      (set-process-coding-system process 
                                 evelnote-coding-system 
                                 evelnote-coding-system)
      ;; (set-process-input-coding-system  process evelnote-coding-system)
      ;; (set-process-output-coding-system process evelnote-coding-system)
      )

    (with-current-buffer (process-buffer process)
      (if (null (accept-process-output process evelnote-timeout-seconds))
          (error "authenticate timeout. please retry later.")

        (goto-char (point-min))
        (block 'auth
          (while (not (eobp))
            (let ((res (read (current-buffer))))
              (cond ((eq res t)
                     (add-hook 'kill-emacs-hook #'evelnote-kill)
                     (message (format "authenticate '%s' success." evelnote-username))
                     (return-from 'auth process))
                    ((eq res 'evelnote-authenticate-faild)
                     (evelnote-kill)
                     (error "authenticate faild. please retry."))
                    ((eq res nil)
                     (evelnote-kill)
                     (error "authenticate '%s' faild. reason: %s"
                            evelnote-username
                            (buffer-substring-no-properties (point-min) (point-max))))
                    )))
          (error "authenticate '%s' faild. reason: %s"
                 evelnote-username
                 (buffer-substring-no-properties (point-min) (point-max))))
          ))))

(defun* evelnote-save (note)
  (unless (evelnote-note-p note)
    (error "invalid note:\"%S\"" note))

  (let* ((content (evelnote-note-content note))
         (content-type (or (and (bufferp content)
                                (save-excursion
                                  (switch-to-buffer content)
                                  (cond ((apply #'derived-mode-p
                                                evelnote-markdown-modes) "Markdown")
                                        ((apply #'derived-mode-p
                                                evelnote-html-modes) "HTML"))))
                           "Preformatted"))
         (filter (if (string-match "HTML" content-type)
                     #'identity
                   #'evelnote-html-quote))
         (field-value))

  (when (null content) (return-from evelnote-save))
  (unless (or (bufferp content)
              (stringp content)) (error "invalid content: %S" content))

  (evelnote-with-edam-buffer
   (send "post note\n")

   (send (format "Content-Type: %s" content-type))
   (dolist (field-name '(guid title notebook-guid))
     (setq field-value
           (funcall (intern (format "evelnote-note-%s" field-name)) note))
     (when (and field-value (< 0 (length field-value)))
       (send (format "%s: %s\n" field-name field-value))))

   (setq field-value (mapconcat #'identity (evelnote-note-tag-names note) ","))
   (when (< 0 (length field-value))
     (send (format "Tag-Names: %s\n" field-value)))
   (send "\n")
   
   (cond ((stringp content)
          (send (evelnote-html-quote
                 (replace-regexp-in-string "^\\.$" ".." content))))

         ((bufferp content)
          (save-excursion
            (switch-to-buffer content)
            (goto-char (point-min))
            (while (< (point-at-eol) (point-max))
              (send
               (funcall filter 
                        (replace-regexp-in-string "^\\.$"
                                                  ".." (thing-at-point 'line))))
              (forward-line)))))
   (send "\n.\n")

   (message "Saving Evernote...")
   ;; (evelnote-start-check-for-save-response buffer-or-content)
   (evelnote-aif (evelnote-wait-and-get-response)
       (progn (when (bufferp content)
                (evelnote-mode-setup it))
              (message "Success Evernote saved."))
     (error "Faild evernote save. invalid response. See \"%s\" buffer."
            evelnote-edam-buffer-name)))))
  
;; 
;; utilities
;; 

(defun evelnote-html-quote (str)
  (replace-regexp-in-string "[&<>\"]"
                            (lambda (m)
                              (or (cdr (assq (string-to-char m)
                                             '((?&  . "&amp;")
                                               (?<  . "&lt;")
                                               (?>  . "&gt;")
                                               (?\" . "&quot;")
                                               )))
                                  m))
                            str))

(defun evelnote-default-notebook ()
  (or (when (evelnote-notebook-p evelnote-default-notebook)
        evelnote-default-notebook)
      (loop for notebook in (evelnote-notebook-list)
            when (and (evelnote-notebook-p notebook)
                      (evelnote-notebook-default-notebook notebook))
            return notebook)))

(defun evelnote-notebook-list ()
  (when (null evelnote-notebook-list)
    (evelnote-reload-notebook-list))
  evelnote-notebook-list)

(defun evelnote-title-for (content-or-buffer)
  (cond ((stringp content-or-buffer)
         (when (string-match "\\w.*$" content-or-buffer)
           (match-string 0 content-or-buffer)))

        ((bufferp content-or-buffer)
         (if evelnote-mode
             (evelnote-note-title evelnote-note)
           (save-excursion
             (switch-to-buffer content-or-buffer)
             (goto-char (point-min))
             (re-search-forward "\\w" (point-max) t)
             (buffer-substring-no-properties (- (point) 1) (point-at-eol)))))))

(defun evelnote-read-notebook-guid ()
  (let* ((default-notebook-name (when (evelnote-default-notebook)
                                  (evelnote-notebook-name
                                   (evelnote-default-notebook))))
         (notebook-name
          (completing-read "notebook: "
                           (mapcar 'evelnote-notebook-name (evelnote-notebook-list))
                           nil t
                           (when default-notebook-name
                             (cons default-notebook-name 0))
                           evelnote-notebook-name-history
                           default-notebook-name)))
    (loop for notebook in (evelnote-notebook-list)
          when (equal notebook-name (evelnote-notebook-name notebook))
          return (evelnote-notebook-guid notebook))))

(defun evelnote-read-tag-names ()
  (let ((tag-names-str (read-string "tags: ")))
    (loop for tag in (split-string tag-names-str)
          collect (replace-regexp-in-string "^\\s-+\\|\\s-+$" "" tag))))

;; 
;; timer
;;

(defun evelnote-start-check-for-save-response (buffer-or-content)
  (if (with-current-buffer evelnote-edam-buffer-name
        (not (equal (point-min) (point-max))))
      (let ((res (evelnote-get-response)))
        (if (evelnote-note-p res)
            (when (bufferp buffer-or-content)
              (with-current-buffer buffer-or-content
                (evelnote-mode-setup res)
                ;; (remhash buffer-or-content evelnote-save-check-timers)
                (message "Success Evernote saved.")))
          (error "Faild evernote save. invalid response. See \"%s\" buffer."
                 evelnote-edam-buffer-name)))
    (run-at-time "3 sec" nil
                 #'evelnote-start-check-for-save-response buffer-or-content)))

;; 
;; global interactive function
;; 

(defun evernote ()
  (interactive)
  (let* ((queries evelnote-notelist-initial-queries)
         (query-list (cond ((listp queries) queries)
                           ((stringp queries) (list queries)))))
    (if (null query-list)
        (command-execute 'evelnote-search)
      (dolist (query query-list)
        (evelnote-search query)))))

(defun evelnote-search (query)
  "search evernote with official query."
  (interactive (list
                (read-string "Search Evernote: " nil evelnote-search-history)))
  (message "Searching evernote...")

  (let ((res (evelnote-send (format "query %s\n" query))))
    (unless (evelnote-notelist-p res)
      (error "invalid response: %S" res))
    (switch-to-buffer (evelnote-notelist-render res query))
    (message "%d notes" (evelnote-notelist-total-notes res))))

(defun evelnote-recent ()
  "listing evernote updated at lasted 3 days."
  (interactive)
  (evelnote-search "updated:day-3"))

(defun evelnote-reload-notebook-list ()
  (interactive)
  (message "Get notebook list...")
  (let ((list (evelnote-send "get notebooks\n")))
    (setq evelnote-notebook-list nil
          evelnote-default-notebook nil)
    (dolist (notebook list)
      (when (evelnote-notebook-p notebook)
        (add-to-list 'evelnote-notebook-list notebook t)
        (when (evelnote-notebook-default-notebook notebook)
          (setq evelnote-default-notebook notebook))))))

(defun* evelnote-quick-save (content)
  (interactive (list (and (evelnote-start)
                          (if (region-active-p)
                              (buffer-substring-no-properties (region-beginning)
                                                              (region-end))
                            (read-string "note: ")))))
  (when (< (length content) 1)
    (return-from evelnote-quick-save))

  (let ((note (make-evelnote-note)))
    (setf (evelnote-note-content note) content
          (evelnote-note-title note) (evelnote-title-for content)
          (evelnote-note-notebook-guid note) (evelnote-read-notebook-guid)
          (evelnote-note-tag-names note) (evelnote-read-tag-names))
    (evelnote-save note)))

(defun evelnote-new (title)
  (interactive "stitle: ")
  (switch-to-buffer
   (with-current-buffer (generate-new-buffer title)
     (evelnote-mode t)
     (current-buffer))))

(provide 'evelnote)
;;; evelnote.el ends here
