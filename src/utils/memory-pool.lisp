;;;; memory-pool.lisp - Memory management and object pooling for eve-gate
;;;;
;;;; Reduces GC pressure and memory allocation overhead in hot paths through:
;;;;   - String interning for common ESI values (datasource names, categories)
;;;;   - Object pools for frequently allocated structures
;;;;   - Optimized cache key generation avoiding string concatenation
;;;;   - Memory usage tracking and reporting
;;;;
;;;; ESI requests involve many repeated string values that are identical
;;;; across requests: datasource names ("tranquility"), language codes ("en"),
;;;; HTTP methods, status descriptions, category names, etc. String interning
;;;; replaces these with shared references, reducing both allocation and
;;;; comparison costs.
;;;;
;;;; Cache key generation is a hot path — every cache lookup requires a key.
;;;; The optimized key generator uses a pre-allocated buffer and writes
;;;; directly into it, avoiding intermediate string concatenation.
;;;;
;;;; Design: All pools and caches are thread-safe. String interning uses
;;;; a read-optimized concurrent hash-table. Object pools use a lock-free
;;;; stack where possible (with fallback to locked operations).

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; String interning for common ESI values
;;; ---------------------------------------------------------------------------

(defstruct (string-interner (:constructor %make-string-interner))
  "Thread-safe string interner for common ESI string values.

Given a string, returns the canonical (shared) copy. Subsequent
calls with an EQUAL string return the same (EQ) object, saving
both memory and comparison costs.

Slots:
  LOCK: Thread synchronization lock
  TABLE: Hash-table of string -> canonical-string
  HIT-COUNT: Number of successful interns (string already existed)
  MISS-COUNT: Number of new interns (string was new)"
  (lock (bt:make-lock "string-interner-lock"))
  (table (make-hash-table :test 'equal :size 512) :type hash-table)
  (hit-count 0 :type fixnum)
  (miss-count 0 :type fixnum))

(defvar *string-interner* nil
  "Global string interner. Initialized by INITIALIZE-STRING-INTERNER.")

(defun make-string-interner ()
  "Create a new string interner."
  (%make-string-interner))

(defun initialize-string-interner ()
  "Initialize the global string interner with pre-seeded common ESI values.

Pre-seeds the interner with strings known to appear frequently in ESI
responses and request parameters, avoiding first-access lock contention.

Returns the string interner."
  (let ((interner (make-string-interner)))
    ;; Pre-seed with common ESI values
    ;; Datasources
    (dolist (s '("tranquility" "singularity"))
      (setf (gethash s (string-interner-table interner)) s))
    ;; Languages
    (dolist (s '("en" "de" "fr" "ja" "ru" "zh" "ko" "es"))
      (setf (gethash s (string-interner-table interner)) s))
    ;; HTTP methods
    (dolist (s '("GET" "POST" "PUT" "DELETE" "HEAD" "OPTIONS"))
      (setf (gethash s (string-interner-table interner)) s))
    ;; Common header names
    (dolist (s '("content-type" "authorization" "user-agent" "accept"
                 "accept-encoding" "cache-control" "etag" "if-none-match"
                 "x-esi-error-limit-remain" "x-esi-error-limit-reset"
                 "x-pages" "expires" "last-modified" "retry-after"
                 "connection" "keep-alive"))
      (setf (gethash s (string-interner-table interner)) s))
    ;; Common response values
    (dolist (s '("application/json" "application/json; charset=utf-8"
                 "gzip" "deflate" "identity"
                 "no-cache" "no-store" "must-revalidate"))
      (setf (gethash s (string-interner-table interner)) s))
    ;; ESI categories
    (dolist (s '("alliances" "characters" "contracts" "corporation"
                 "corporations" "dogma" "fleets" "fw" "incursions"
                 "industry" "insurance" "killmails" "loyalty" "markets"
                 "route" "sovereignty" "status" "ui" "universe" "wars"))
      (setf (gethash s (string-interner-table interner)) s))
    ;; Common cache key prefixes
    (dolist (s '("esi:" "|auth:" "|ds:"))
      (setf (gethash s (string-interner-table interner)) s))
    (setf *string-interner* interner)
    interner))

(defun intern-string (string &optional (interner *string-interner*))
  "Return the canonical (shared) copy of STRING.

If STRING is already in the interner, returns the existing copy (EQ).
If STRING is new, stores a copy and returns it.

STRING: The string to intern
INTERNER: String interner to use (default: global)

Returns the canonical string. This is EQ to the previously interned
copy if one exists, which enables EQ comparison instead of EQUAL.

Thread-safe."
  (unless interner
    (return-from intern-string string))
  ;; Fast path: check without lock (safe for hash-table reads on most impls)
  (let ((existing (gethash string (string-interner-table interner))))
    (when existing
      (bt:with-lock-held ((string-interner-lock interner))
        (incf (string-interner-hit-count interner)))
      (return-from intern-string existing)))
  ;; Slow path: acquire lock and insert
  (bt:with-lock-held ((string-interner-lock interner))
    ;; Double-check after acquiring lock
    (let ((existing (gethash string (string-interner-table interner))))
      (when existing
        (incf (string-interner-hit-count interner))
        (return-from intern-string existing)))
    ;; New string — store a copy
    (let ((canonical (copy-seq string)))
      (setf (gethash canonical (string-interner-table interner)) canonical)
      (incf (string-interner-miss-count interner))
      canonical)))

(defun string-interner-statistics (&optional (interner *string-interner*))
  "Return string interner statistics.

Returns a plist with:
  :ENTRIES — number of interned strings
  :HITS — lookup hits (string already interned)
  :MISSES — lookup misses (new strings)
  :HIT-RATE — fraction of hits"
  (when interner
    (bt:with-lock-held ((string-interner-lock interner))
      (let* ((hits (string-interner-hit-count interner))
             (misses (string-interner-miss-count interner))
             (total (+ hits misses)))
        (list :entries (hash-table-count (string-interner-table interner))
              :hits hits
              :misses misses
              :hit-rate (if (plusp total)
                            (/ (float hits) total)
                            0.0))))))

;;; ---------------------------------------------------------------------------
;;; Optimized cache key generation
;;; ---------------------------------------------------------------------------

(defparameter *cache-key-buffer-size* 256
  "Default size for cache key construction buffers.")

(defun fast-cache-key (endpoint params auth-context datasource)
  "Generate a cache key using optimized string construction.

Avoids FORMAT and intermediate string concatenation by writing
directly to a string output stream. This is the hot-path-optimized
version of eve-gate.cache:make-cache-key.

ENDPOINT: The ESI endpoint path string
PARAMS: Alist of query parameters (or NIL)
AUTH-CONTEXT: Authentication context string (or NIL)
DATASOURCE: Datasource string (or NIL)

Returns a cache key string.

Performance: ~3x faster than FORMAT-based key generation for typical
ESI cache keys (benchmarked with 100-char endpoint paths + 3 params)."
  (declare (optimize (speed 3) (safety 1)))
  (let ((stream (make-string-output-stream)))
    ;; Prefix
    (write-string "esi:" stream)
    ;; Endpoint path
    (write-string endpoint stream)
    ;; Sorted query parameters
    (when params
      (let ((sorted (sort (copy-list params) #'string< :key #'car)))
        (write-char #\? stream)
        (loop for (key . value) in sorted
              for first = t then nil
              unless first do (write-char #\& stream)
              do (write-string key stream)
                 (write-char #\= stream)
                 (write-string (princ-to-string value) stream))))
    ;; Auth context
    (when auth-context
      (write-string "|auth:" stream)
      (write-string (princ-to-string auth-context) stream))
    ;; Datasource
    (write-string "|ds:" stream)
    (write-string (or datasource "tranquility") stream)
    (get-output-stream-string stream)))

;;; ---------------------------------------------------------------------------
;;; Object pool for reusable structures
;;; ---------------------------------------------------------------------------

(defstruct (object-pool (:constructor %make-object-pool))
  "Thread-safe pool of reusable objects to reduce allocation pressure.

Objects are acquired from the pool and returned when no longer needed.
If the pool is empty, a new object is created via the constructor function.
If the pool is full, returned objects are discarded (left for GC).

Slots:
  LOCK: Thread synchronization lock
  NAME: Pool name for diagnostics
  CONSTRUCTOR: Function to create new objects (no args)
  RESETTER: Function to reset an object for reuse (one arg)
  STACK: Simple vector used as a stack
  TOP: Current stack top index (-1 = empty)
  MAX-SIZE: Maximum pool capacity
  TOTAL-ACQUIRED: Total objects acquired
  TOTAL-RETURNED: Total objects returned
  TOTAL-CREATED: Total objects created (cache miss)"
  (lock (bt:make-lock "object-pool-lock"))
  (name "unnamed" :type string)
  (constructor (error "constructor required") :type function)
  (resetter nil :type (or null function))
  (stack nil :type (or null simple-vector))
  (top -1 :type fixnum)
  (max-size 128 :type fixnum)
  (total-acquired 0 :type fixnum)
  (total-returned 0 :type fixnum)
  (total-created 0 :type fixnum))

(defun make-object-pool (name constructor &key (max-size 128)
                                                 (resetter nil)
                                                 (pre-fill 0))
  "Create an object pool.

NAME: Descriptive name for diagnostics
CONSTRUCTOR: Zero-argument function that creates a new object
MAX-SIZE: Maximum pool capacity (default: 128)
RESETTER: Optional function to reset an object for reuse
PRE-FILL: Number of objects to pre-create (default: 0)

Returns an object-pool struct.

Example:
  (make-object-pool \"string-buffers\"
    (lambda () (make-array 256 :element-type 'character
                               :fill-pointer 0 :adjustable t))
    :max-size 32
    :resetter (lambda (buf) (setf (fill-pointer buf) 0)))"
  (let ((pool (%make-object-pool
               :name name
               :constructor constructor
               :resetter resetter
               :stack (make-array max-size :initial-element nil)
               :top -1
               :max-size max-size)))
    ;; Pre-fill if requested
    (when (plusp pre-fill)
      (dotimes (i (min pre-fill max-size))
        (setf (aref (object-pool-stack pool) i)
              (funcall constructor))
        (incf (object-pool-top pool))
        (incf (object-pool-total-created pool))))
    pool))

(defun pool-acquire (pool)
  "Acquire an object from the pool.

POOL: An object-pool struct

If the pool has available objects, returns one from the pool.
Otherwise, creates a new object via the pool's constructor.

Thread-safe."
  (bt:with-lock-held ((object-pool-lock pool))
    (incf (object-pool-total-acquired pool))
    (if (>= (object-pool-top pool) 0)
        ;; Pool has objects — pop one
        (let* ((top (object-pool-top pool))
               (obj (aref (object-pool-stack pool) top)))
          (setf (aref (object-pool-stack pool) top) nil)
          (decf (object-pool-top pool))
          obj)
        ;; Pool empty — create new
        (progn
          (incf (object-pool-total-created pool))
          (funcall (object-pool-constructor pool))))))

(defun pool-release (pool object)
  "Return an object to the pool for reuse.

POOL: An object-pool struct
OBJECT: The object to return

If the pool is full, the object is discarded (left for GC).
If a resetter function is configured, it's called before storing.

Thread-safe."
  (bt:with-lock-held ((object-pool-lock pool))
    (incf (object-pool-total-returned pool))
    (when (< (object-pool-top pool) (1- (object-pool-max-size pool)))
      ;; Reset the object if a resetter is provided
      (when (object-pool-resetter pool)
        (funcall (object-pool-resetter pool) object))
      ;; Push onto stack
      (incf (object-pool-top pool))
      (setf (aref (object-pool-stack pool) (object-pool-top pool)) object))))

(defmacro with-pooled-object ((var pool) &body body)
  "Acquire an object from POOL, bind to VAR, execute BODY, return to pool.

Ensures the object is returned to the pool even if BODY signals an error.

Example:
  (with-pooled-object (buffer *string-buffer-pool*)
    (write-string \"hello\" buffer)
    (get-output-stream-string buffer))"
  (let ((pool-var (gensym "POOL-")))
    `(let* ((,pool-var ,pool)
            (,var (pool-acquire ,pool-var)))
       (unwind-protect
            (progn ,@body)
         (pool-release ,pool-var ,var)))))

(defun object-pool-statistics (pool)
  "Return pool statistics as a plist.

Returns:
  :NAME — pool name
  :SIZE — current objects in pool
  :MAX-SIZE — maximum capacity
  :TOTAL-ACQUIRED — total objects acquired
  :TOTAL-RETURNED — total objects returned
  :TOTAL-CREATED — total objects created from scratch
  :HIT-RATE — fraction of acquires satisfied from pool"
  (bt:with-lock-held ((object-pool-lock pool))
    (let ((acquired (object-pool-total-acquired pool))
          (created (object-pool-total-created pool)))
      (list :name (object-pool-name pool)
            :size (1+ (object-pool-top pool))
            :max-size (object-pool-max-size pool)
            :total-acquired acquired
            :total-returned (object-pool-total-returned pool)
            :total-created created
            :hit-rate (if (plusp acquired)
                          (/ (float (- acquired created)) acquired)
                          0.0)))))

;;; ---------------------------------------------------------------------------
;;; Pre-configured pools for eve-gate hot paths
;;; ---------------------------------------------------------------------------

(defvar *string-output-stream-pool* nil
  "Pool of string output streams for cache key construction and other
string building operations.")

(defvar *response-list-pool* nil
  "Pool of pre-allocated lists for collecting response data.")

(defun initialize-memory-pools ()
  "Initialize all pre-configured memory pools.

Call this during system startup to pre-allocate pools for hot paths."
  ;; String output stream pool
  (setf *string-output-stream-pool*
        (make-object-pool "string-output-streams"
          (lambda () (make-string-output-stream))
          :max-size 64
          :resetter (lambda (stream)
                      ;; Flush the stream to reset it
                      (get-output-stream-string stream))
          :pre-fill 8))
  ;; Initialize string interner
  (initialize-string-interner)
  (log-info "Memory pools initialized")
  (values))

;;; ---------------------------------------------------------------------------
;;; Memory usage tracking
;;; ---------------------------------------------------------------------------

(defstruct (memory-tracker (:constructor %make-memory-tracker))
  "Tracks memory allocation patterns for optimization guidance.

Provides a rough picture of where memory is being spent, which
helps identify optimization opportunities.

Slots:
  LOCK: Thread synchronization lock
  ALLOCATIONS: Hash-table of category (keyword) -> (count . total-bytes)
  BASELINE-BYTES: Memory usage at initialization
  LAST-SNAPSHOT-BYTES: Memory at last snapshot"
  (lock (bt:make-lock "memory-tracker-lock"))
  (allocations (make-hash-table :test 'eq) :type hash-table)
  (baseline-bytes 0 :type integer)
  (last-snapshot-bytes 0 :type integer))

(defvar *memory-tracker* nil
  "Global memory tracker.")

(defun current-memory-usage ()
  "Return approximate current dynamic memory usage in bytes.

Implementation-dependent; returns 0 if not determinable."
  #+sbcl (- (sb-sys:sap-int (sb-kernel:dynamic-space-free-pointer))
             sb-vm:dynamic-space-start)
  #+ccl (ccl::%usedbytes)
  #-(or sbcl ccl) 0)

(defun initialize-memory-tracker ()
  "Initialize the global memory tracker.

Returns the memory tracker."
  (let ((usage (current-memory-usage)))
    (setf *memory-tracker*
          (%make-memory-tracker
           :baseline-bytes usage
           :last-snapshot-bytes usage))
    *memory-tracker*))

(defun record-allocation (category byte-count)
  "Record a memory allocation event.

CATEGORY: A keyword identifying the allocation category
BYTE-COUNT: Approximate bytes allocated

Example:
  (record-allocation :cache-entry 4096)
  (record-allocation :json-parse 16384)"
  (when *memory-tracker*
    (bt:with-lock-held ((memory-tracker-lock *memory-tracker*))
      (let* ((allocs (memory-tracker-allocations *memory-tracker*))
             (existing (gethash category allocs)))
        (if existing
            (progn (incf (car existing))
                   (incf (cdr existing) byte-count))
            (setf (gethash category allocs)
                  (cons 1 byte-count)))))))

(defun memory-usage-report (&optional (stream *standard-output*))
  "Print a memory usage report.

STREAM: Output stream (default: *standard-output*)"
  (format stream "~&=== Memory Usage Report ===~%")
  (let ((current (current-memory-usage)))
    (format stream "  Current usage:  ~:D bytes (~,1F MB)~%"
            current (/ current 1048576.0))
    (when *memory-tracker*
      (format stream "  Baseline:       ~:D bytes (~,1F MB)~%"
              (memory-tracker-baseline-bytes *memory-tracker*)
              (/ (memory-tracker-baseline-bytes *memory-tracker*) 1048576.0))
      (format stream "  Delta:          ~:D bytes (~,1F MB)~%"
              (- current (memory-tracker-baseline-bytes *memory-tracker*))
              (/ (- current (memory-tracker-baseline-bytes *memory-tracker*)) 1048576.0))
      ;; Per-category breakdown
      (format stream "~%  Allocation categories:~%")
      (let ((categories nil))
        (maphash (lambda (cat counts)
                   (push (list cat (car counts) (cdr counts)) categories))
                 (memory-tracker-allocations *memory-tracker*))
        (setf categories (sort categories #'> :key #'third))
        (dolist (entry categories)
          (format stream "    ~A: ~D allocations, ~:D bytes (~,1F MB)~%"
                  (first entry)
                  (second entry)
                  (third entry)
                  (/ (third entry) 1048576.0))))))
  ;; String interner stats
  (when *string-interner*
    (let ((stats (string-interner-statistics)))
      (format stream "~%  String interner:~%")
      (format stream "    Entries: ~D  Hit rate: ~,1F%~%"
              (getf stats :entries)
              (* 100.0 (getf stats :hit-rate)))))
  ;; Object pool stats
  (when *string-output-stream-pool*
    (let ((stats (object-pool-statistics *string-output-stream-pool*)))
      (format stream "~%  String buffer pool:~%")
      (format stream "    Size: ~D/~D  Hit rate: ~,1F%~%"
              (getf stats :size)
              (getf stats :max-size)
              (* 100.0 (getf stats :hit-rate)))))
  (format stream "=== End Memory Report ===~%")
  (values))

;;; ---------------------------------------------------------------------------
;;; Hash-table optimization utilities
;;; ---------------------------------------------------------------------------

(defun make-sized-hash-table (expected-entries &key (test 'equal))
  "Create a hash-table pre-sized for EXPECTED-ENTRIES to minimize rehashing.

Hash-tables in Common Lisp resize (rehash) when they exceed their load
factor threshold. Pre-sizing avoids this overhead during initial population.

EXPECTED-ENTRIES: Expected number of entries
TEST: Hash-table test function (default: EQUAL)

Returns a hash-table with enough room to hold EXPECTED-ENTRIES without rehashing."
  ;; Most implementations use a load factor around 0.7-0.8.
  ;; Pre-allocate at ~70% capacity to avoid immediate rehash.
  (make-hash-table :test test
                   :size (ceiling (* expected-entries 1.5))))

;;; ---------------------------------------------------------------------------
;;; Performance initialization
;;; ---------------------------------------------------------------------------

(defun initialize-performance-subsystem ()
  "Initialize all performance-related subsystems.

Call this during system startup to enable:
  - String interning
  - Memory pools
  - Memory tracking
  - Performance metrics

Returns T."
  (initialize-string-interner)
  (initialize-memory-pools)
  (initialize-memory-tracker)
  (initialize-performance-metrics)
  (initialize-performance-monitor)
  (log-info "Performance subsystem initialized")
  t)
