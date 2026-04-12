;;;; logging.lisp - Logging utilities for eve-gate

(in-package #:eve-gate.utils)

(defparameter *log-level* :info
  "Current logging level (:debug :info :warn :error).")

(defun log-debug (format-string &rest args)
  "Log debug message."
  (when (log-level-active-p :debug)
    (apply #'format t (concatenate 'string "[DEBUG] " format-string "~%") args)))

(defun log-info (format-string &rest args)
  "Log info message."
  (when (log-level-active-p :info)
    (apply #'format t (concatenate 'string "[INFO] " format-string "~%") args)))

(defun log-warn (format-string &rest args)
  "Log warning message."
  (when (log-level-active-p :warn)
    (apply #'format t (concatenate 'string "[WARN] " format-string "~%") args)))

(defun log-error (format-string &rest args)
  "Log error message."
  (when (log-level-active-p :error)
    (apply #'format t (concatenate 'string "[ERROR] " format-string "~%") args)))

(defun log-level-active-p (level)
  "Check if logging level is active."
  (let ((levels '(:debug :info :warn :error))
        (current-pos (position *log-level* '(:debug :info :warn :error)))
        (level-pos (position level '(:debug :info :warn :error))))
    (and current-pos level-pos (>= level-pos current-pos))))

(defmacro with-logging ((level) &body body)
  "Execute body with specific logging level."
  `(let ((*log-level* ,level))
     ,@body))