;; -*-lisp-*-
(defpackage :eve-gate
            (:use :cl)
            (:use :eve-gate.app-utils)
            (:export :-main))

(in-package :eve-gate)

(defun -main (&optional args)
  (format t "~a~%" "I don't do much yet"))

