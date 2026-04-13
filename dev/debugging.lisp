;;;; debugging.lisp - Development debugging utilities for eve-gate
;;;;
;;;; Provides diagnostic tools for inspecting system state during development:
;;;;   - System health overview
;;;;   - Component status inspection
;;;;   - Performance monitoring dashboard
;;;;   - Memory analysis utilities

(defpackage #:eve-gate.dev.debugging
  (:use #:cl #:alexandria)
  (:import-from #:eve-gate.utils
                #:performance-report
                #:memory-usage-report
                #:string-interner-statistics
                #:*perf-metrics*
                #:*esi-perf-monitor*
                #:*string-interner*
                #:*memory-tracker*
                #:current-memory-usage)
  (:import-from #:eve-gate.core
                #:connection-pool-status
                #:connection-pool-statistics)
  (:export
   #:system-health-check
   #:full-diagnostic-report))

(in-package #:eve-gate.dev.debugging)

(defun system-health-check (&optional (stream *standard-output*))
  "Print a quick health check of all eve-gate subsystems.

STREAM: Output stream (default: *standard-output*)"
  (format stream "~&=== EVE-GATE System Health Check ===~%")
  (format stream "  Lisp:        ~A ~A~%"
          (lisp-implementation-type) (lisp-implementation-version))
  (format stream "  Memory:      ~,1F MB in use~%"
          (/ (current-memory-usage) 1048576.0))
  ;; Performance subsystem
  (format stream "  Performance: ~A~%"
          (if eve-gate.utils:*perf-metrics* "ACTIVE" "NOT INITIALIZED"))
  ;; String interner
  (when eve-gate.utils:*string-interner*
    (let ((stats (string-interner-statistics)))
      (format stream "  Interner:    ~D entries, ~,1F% hit rate~%"
              (getf stats :entries)
              (* 100.0 (getf stats :hit-rate)))))
  ;; Connection pool
  (format stream "  Conn pool:   ~A~%"
          (if eve-gate.core:*connection-pool-config* "CONFIGURED" "NOT INITIALIZED"))
  (format stream "=== End Health Check ===~%")
  (values))

(defun full-diagnostic-report (&optional (stream *standard-output*))
  "Print a comprehensive diagnostic report of all subsystems.

STREAM: Output stream (default: *standard-output*)"
  (format stream "~&╔══════════════════════════════════════════════╗~%")
  (format stream   "║        EVE-GATE DIAGNOSTIC REPORT            ║~%")
  (format stream   "╚══════════════════════════════════════════════╝~%~%")
  ;; Health check
  (system-health-check stream)
  (terpri stream)
  ;; Performance metrics
  (performance-report :stream stream)
  (terpri stream)
  ;; Connection pool
  (connection-pool-status stream)
  (terpri stream)
  ;; Memory
  (memory-usage-report stream)
  (format stream "~&Diagnostic report complete.~%")
  (values))
