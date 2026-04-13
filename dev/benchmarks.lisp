;;;; benchmarks.lisp - Performance benchmarks for eve-gate
;;;;
;;;; Provides reproducible benchmarks for measuring the performance of
;;;; eve-gate's core subsystems: cache operations, HTTP request overhead,
;;;; rate limiter throughput, and memory allocation patterns.
;;;;
;;;; Usage from the REPL:
;;;;   (asdf:load-system :eve-gate/dev)
;;;;   (eve-gate.dev.benchmarks:run-all-benchmarks)
;;;;
;;;; Individual benchmarks can be run independently for targeted analysis.

(defpackage #:eve-gate.dev.benchmarks
  (:use #:cl #:alexandria)
  (:import-from #:eve-gate.utils
                #:benchmark
                #:get-precise-time
                #:elapsed-milliseconds
                #:elapsed-microseconds
                #:performance-report
                #:make-latency-histogram
                #:histogram-record
                #:histogram-stats
                #:make-throughput-tracker
                #:throughput-record
                #:throughput-rate
                #:fast-cache-key
                #:make-object-pool
                #:pool-acquire
                #:pool-release
                #:with-pooled-object
                #:intern-string
                #:initialize-performance-subsystem)
  (:import-from #:eve-gate.cache
                #:make-memory-cache
                #:memory-cache-get
                #:memory-cache-put
                #:memory-cache-statistics
                #:make-cache-key)
  (:import-from #:eve-gate.core
                #:make-rate-limiter)
  (:export
   #:run-all-benchmarks
   #:bench-cache-operations
   #:bench-cache-key-generation
   #:bench-string-interning
   #:bench-object-pool
   #:bench-latency-histogram
   #:bench-throughput-tracker))

(in-package #:eve-gate.dev.benchmarks)

;;; ---------------------------------------------------------------------------
;;; Cache operation benchmarks
;;; ---------------------------------------------------------------------------

(defun bench-cache-operations (&key (iterations 10000) (cache-size 5000))
  "Benchmark memory cache get/put operations.

Tests pure cache operation speed without any network I/O."
  (format t "~&=== Cache Operation Benchmarks ===~%")
  (let ((cache (make-memory-cache :max-entries cache-size)))
    ;; Pre-populate cache
    (dotimes (i (min iterations cache-size))
      (memory-cache-put cache
                        (format nil "bench-key-~D" i)
                        (format nil "bench-value-~D" i)
                        :ttl 3600))
    ;; Benchmark cache hits
    (format t "~%Cache GET (hit):~%")
    (benchmark (:iterations iterations :warmup 1000 :label "cache-get-hit")
      (memory-cache-get cache (format nil "bench-key-~D" (random (min iterations cache-size)))))
    ;; Benchmark cache misses
    (format t "~%Cache GET (miss):~%")
    (benchmark (:iterations iterations :warmup 1000 :label "cache-get-miss")
      (memory-cache-get cache (format nil "nonexistent-key-~D" (random iterations))))
    ;; Benchmark cache puts
    (format t "~%Cache PUT:~%")
    (benchmark (:iterations iterations :warmup 1000 :label "cache-put")
      (memory-cache-put cache
                        (format nil "put-key-~D" (random iterations))
                        "test-value"
                        :ttl 300))
    ;; Print final stats
    (format t "~%Cache statistics after benchmark:~%")
    (let ((stats (memory-cache-statistics cache)))
      (format t "  Hit rate: ~,1F%  Count: ~D~%"
              (* 100.0 (getf stats :hit-rate))
              (getf stats :count)))))

;;; ---------------------------------------------------------------------------
;;; Cache key generation benchmark
;;; ---------------------------------------------------------------------------

(defun bench-cache-key-generation (&key (iterations 50000))
  "Benchmark cache key generation performance.

Compares the optimized FAST-CACHE-KEY with FORMAT-based key generation."
  (format t "~&=== Cache Key Generation Benchmarks ===~%")
  (let ((endpoint "/v5/characters/95465499/assets")
        (params '(("page" . "1") ("datasource" . "tranquility")))
        (auth-context "95465499")
        (datasource "tranquility"))
    ;; Optimized (stream-based)
    (format t "~%Optimized (fast-cache-key):~%")
    (benchmark (:iterations iterations :warmup 5000 :label "fast-cache-key")
      (fast-cache-key endpoint params auth-context datasource))
    ;; Original (FORMAT-based) for comparison
    (format t "~%FORMAT-based key generation:~%")
    (benchmark (:iterations iterations :warmup 5000 :label "format-cache-key")
      (let* ((sorted-params (sort (copy-list params) #'string< :key #'car))
             (param-string (format nil "~{~A=~A~^&~}"
                                   (loop for (k . v) in sorted-params
                                         collect k collect v))))
        (format nil "esi:~A~@[?~A~]~@[|auth:~A~]|ds:~A"
                endpoint
                (when (plusp (length param-string)) param-string)
                auth-context
                datasource)))))

;;; ---------------------------------------------------------------------------
;;; String interning benchmark
;;; ---------------------------------------------------------------------------

(defun bench-string-interning (&key (iterations 100000))
  "Benchmark string interning vs raw string operations."
  (format t "~&=== String Interning Benchmarks ===~%")
  (initialize-performance-subsystem)
  (let ((test-strings '("tranquility" "en" "application/json"
                         "characters" "markets" "universe"
                         "get_characters_character_id" "etag"
                         "cache-control" "content-type")))
    ;; Intern lookup (hot path)
    (format t "~%String intern (cached hit):~%")
    (benchmark (:iterations iterations :warmup 10000 :label "intern-string-hit")
      (intern-string (nth (random (length test-strings)) test-strings)))
    ;; Raw EQUAL comparison baseline
    (format t "~%String EQUAL comparison (baseline):~%")
    (let ((target "application/json"))
      (benchmark (:iterations iterations :warmup 10000 :label "string-equal")
        (string= target "application/json")))))

;;; ---------------------------------------------------------------------------
;;; Object pool benchmark
;;; ---------------------------------------------------------------------------

(defun bench-object-pool (&key (iterations 50000))
  "Benchmark object pool acquire/release vs fresh allocation."
  (format t "~&=== Object Pool Benchmarks ===~%")
  (let ((pool (make-object-pool "bench-pool"
                (lambda () (make-array 256 :element-type 'character
                                           :fill-pointer 0
                                           :adjustable t))
                :max-size 64
                :resetter (lambda (buf) (setf (fill-pointer buf) 0))
                :pre-fill 32)))
    ;; Pooled allocation
    (format t "~%Pooled acquire/release:~%")
    (benchmark (:iterations iterations :warmup 5000 :label "pool-acquire-release")
      (let ((obj (pool-acquire pool)))
        (pool-release pool obj)))
    ;; Fresh allocation (for comparison)
    (format t "~%Fresh allocation (no pool):~%")
    (benchmark (:iterations iterations :warmup 5000 :label "fresh-allocation")
      (make-array 256 :element-type 'character
                      :fill-pointer 0
                      :adjustable t))))

;;; ---------------------------------------------------------------------------
;;; Latency histogram benchmark
;;; ---------------------------------------------------------------------------

(defun bench-latency-histogram (&key (iterations 100000))
  "Benchmark histogram recording and percentile computation."
  (format t "~&=== Latency Histogram Benchmarks ===~%")
  (let ((hist (make-latency-histogram)))
    ;; Recording
    (format t "~%Histogram record:~%")
    (benchmark (:iterations iterations :warmup 10000 :label "histogram-record")
      (histogram-record hist (+ 10.0 (random 100.0))))
    ;; Percentile computation
    (format t "~%Histogram percentile (p95):~%")
    (benchmark (:iterations 10000 :warmup 1000 :label "histogram-p95")
      (histogram-stats hist))))

;;; ---------------------------------------------------------------------------
;;; Throughput tracker benchmark
;;; ---------------------------------------------------------------------------

(defun bench-throughput-tracker (&key (iterations 100000))
  "Benchmark throughput tracker recording and rate computation."
  (format t "~&=== Throughput Tracker Benchmarks ===~%")
  (let ((tracker (make-throughput-tracker)))
    ;; Recording
    (format t "~%Throughput record:~%")
    (benchmark (:iterations iterations :warmup 10000 :label "throughput-record")
      (throughput-record tracker))
    ;; Rate computation
    (format t "~%Throughput rate computation:~%")
    (benchmark (:iterations 10000 :warmup 1000 :label "throughput-rate")
      (throughput-rate tracker :window 10))))

;;; ---------------------------------------------------------------------------
;;; Run all benchmarks
;;; ---------------------------------------------------------------------------

(defun run-all-benchmarks ()
  "Run all performance benchmarks and print a summary report.

Call this from the REPL:
  (eve-gate.dev.benchmarks:run-all-benchmarks)"
  (format t "~&╔══════════════════════════════════════════════╗~%")
  (format t   "║        EVE-GATE PERFORMANCE BENCHMARKS       ║~%")
  (format t   "╚══════════════════════════════════════════════╝~%~%")
  (format t "Implementation: ~A ~A~%"
          (lisp-implementation-type)
          (lisp-implementation-version))
  (format t "Date: ~A~%~%" (get-universal-time))
  ;; Initialize subsystem
  (initialize-performance-subsystem)
  ;; Run benchmarks
  (bench-cache-key-generation)
  (terpri)
  (bench-string-interning)
  (terpri)
  (bench-object-pool)
  (terpri)
  (bench-latency-histogram)
  (terpri)
  (bench-throughput-tracker)
  (terpri)
  (bench-cache-operations)
  (terpri)
  ;; Print overall performance report
  (performance-report)
  (format t "~&Benchmarks complete.~%"))
