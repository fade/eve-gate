;;;; repl-utils.lisp - Development utilities for REPL-driven development

(defpackage #:eve-gate.dev
  (:use #:cl #:alexandria #:eve-gate)
  (:export
   #:quick-start
   #:reload-system
   #:run-tests
   #:benchmark
   #:profile-function
   #:inspect-api-response
   #:test-endpoint
   #:*dev-config*))

(in-package #:eve-gate.dev)

(defparameter *dev-config*
  '(:log-level :debug
    :cache-enabled nil
    :rate-limiting nil
    :mock-responses t)
  "Development configuration overrides.")

(defun quick-start ()
  "Quick setup for REPL development sessions."
  (format t "~&Starting eve-gate development environment...~%")
  
  ;; Load system
  (asdf:load-system :eve-gate :verbose t)
  
  ;; Apply dev config
  (eve-gate.utils:load-config *dev-config*)
  
  ;; Set up development logging
  (setf eve-gate.utils:*log-level* :debug)
  
  (format t "~&Ready! Try: (make-eve-client)~%")
  (format t "~&Useful functions: reload-system, run-tests, test-endpoint~%")
  
  :ready)

(defun reload-system (&optional (system :eve-gate))
  "Reload the system for iterative development."
  (asdf:load-system system :force t)
  (format t "~&System ~A reloaded.~%" system))

(defun run-tests (&optional (system :eve-gate/tests))
  "Run the test suite."
  (asdf:test-system system))

(defun benchmark (function-name &key (iterations 1000) (args '()))
  "Simple benchmarking utility."
  (format t "~&Benchmarking ~A (~A iterations)...~%" function-name iterations)
  (let ((start-time (get-internal-run-time))
        (function (symbol-function function-name)))
    (dotimes (i iterations)
      (apply function args))
    (let ((elapsed (/ (- (get-internal-run-time) start-time)
                     internal-time-units-per-second)))
      (format t "~&Total time: ~,3F seconds~%" elapsed)
      (format t "~&Average per call: ~,6F seconds~%" (/ elapsed iterations))
      elapsed)))

(defun profile-function (function-name)
  "Profile a function (requires implementation-specific profiler)."
  #+sbcl
  (progn
    (sb-profile:profile function-name)
    (format t "~&Profiling enabled for ~A. Call (sb-profile:report) after testing.~%" 
            function-name))
  #-sbcl
  (format t "~&Profiling not implemented for this Lisp implementation.~%"))

(defun inspect-api-response (response)
  "Pretty-print API response for debugging."
  (format t "~&=== API Response ===~%")
  (format t "Status: ~A~%" (eve-gate.types:api-response-status response))
  (format t "Headers: ~A~%" (eve-gate.types:api-response-headers response))
  (format t "ETag: ~A~%" (eve-gate.types:api-response-etag response))
  (format t "Data: ~A~%" (eve-gate.types:api-response-data response))
  response)

(defun test-endpoint (endpoint &key (method :get) parameters headers)
  "Quick endpoint testing utility."
  (format t "~&Testing endpoint: ~A (~A)~%" endpoint method)
  (handler-case
      (let* ((client (make-eve-client))
             (response (eve-gate.api:api-call client endpoint 
                                             :method method
                                             :parameters parameters 
                                             :headers headers)))
        (inspect-api-response response))
    (error (e)
      (format t "~&Error: ~A~%" e)
      nil)))

;; Auto-start in development
(eval-when (:load-toplevel :execute)
  (format t "~&eve-gate development utilities loaded.~%")
  (format t "~&Call (eve-gate.dev:quick-start) to begin.~%"))