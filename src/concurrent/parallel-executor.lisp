;;;; parallel-executor.lisp - lparallel-based parallel operations for eve-gate
;;;;
;;;; Provides high-level parallel operation orchestration using lparallel's
;;;; kernel, futures, and parallel map functions. This module bridges the gap
;;;; between lparallel's CPU-parallel primitives and the I/O-bound nature of
;;;; ESI API requests.
;;;;
;;;; Key concepts:
;;;;   - Kernel management: Shared lparallel kernel lifecycle
;;;;   - Parallel map: pmap/pmapcar over ESI operations with rate limiting
;;;;   - Futures: Non-blocking ESI request submission with future-based results
;;;;   - Smart partitioning: Chunk sizes tuned to I/O vs CPU workloads
;;;;   - Result aggregation: Parallel collection and merging of paged results
;;;;
;;;; The executor works alongside the concurrent engine — the engine manages
;;;; the request queue and worker pool, while the executor provides lparallel
;;;; integration for higher-level parallel patterns.
;;;;
;;;; Thread safety: All shared state protected by locks. The lparallel kernel
;;;; is created once and shared across the process.

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Kernel management
;;; ---------------------------------------------------------------------------

(defvar *parallel-kernel* nil
  "Shared lparallel kernel for ESI parallel operations.
Initialized by ENSURE-PARALLEL-KERNEL, shut down by SHUTDOWN-PARALLEL-KERNEL.")

(defvar *parallel-kernel-lock* (bt:make-lock "parallel-kernel-lock")
  "Lock protecting *parallel-kernel* initialization.")

(defun ensure-parallel-kernel (&key (worker-count nil))
  "Ensure the shared lparallel kernel is initialized.

WORKER-COUNT: Number of lparallel worker threads. Defaults to the number
  of available CPU cores (via sysconf or a reasonable default of 4).

Returns the lparallel kernel.

This is idempotent — calling it when a kernel already exists returns the
existing kernel unless the worker count has changed."
  (bt:with-lock-held (*parallel-kernel-lock*)
    (let ((desired-count (or worker-count (default-worker-count))))
      (when *parallel-kernel*
        (let ((lparallel:*kernel* *parallel-kernel*))
          (when (= (lparallel:kernel-worker-count) desired-count)
            (return-from ensure-parallel-kernel *parallel-kernel*))))
      ;; Shut down existing kernel if worker count changed
      (when *parallel-kernel*
        (let ((lparallel:*kernel* *parallel-kernel*))
          (lparallel:end-kernel :wait t))
        (setf *parallel-kernel* nil))
      ;; Create new kernel
      (setf *parallel-kernel*
            (lparallel:make-kernel desired-count
                                    :name "eve-gate-parallel"))
      (log-info "Parallel kernel initialized with ~D workers" desired-count)
      *parallel-kernel*)))

(defun shutdown-parallel-kernel (&key (wait t))
  "Shut down the shared lparallel kernel.

WAIT: If T (default), wait for running tasks to complete."
  (bt:with-lock-held (*parallel-kernel-lock*)
    (when *parallel-kernel*
      (let ((lparallel:*kernel* *parallel-kernel*))
        (lparallel:end-kernel :wait wait))
      (setf *parallel-kernel* nil)
      (log-info "Parallel kernel shut down")))
  (values))

(defun default-worker-count ()
  "Return a reasonable default worker count for parallel operations.

For I/O-bound ESI work, more workers than CPU cores is beneficial since
threads spend most of their time waiting on network I/O. Returns
approximately 2x the CPU core count, clamped between 4 and 32."
  (let ((cores (max 2 (or (cpu-core-count) 4))))
    (min 32 (max 4 (* 2 cores)))))

(defun cpu-core-count ()
  "Attempt to determine the number of CPU cores available.

Returns an integer, or NIL if detection fails."
  #+sbcl (or (ignore-errors
               (parse-integer
                (with-output-to-string (s)
                  (sb-ext:run-program "/usr/bin/nproc" nil
                                       :output s :error nil))
                :junk-allowed t))
             4)
  #+ccl (or (ignore-errors (ccl:cpu-count)) 4)
  #-(or sbcl ccl) 4)

(defmacro with-parallel-kernel ((&key (worker-count nil)) &body body)
  "Execute BODY with the lparallel kernel bound and available.

Ensures the parallel kernel is initialized, binds lparallel:*kernel*
to it, and executes BODY. The kernel persists after this form returns.

WORKER-COUNT: Optional worker thread count override.

Example:
  (with-parallel-kernel ()
    (lparallel:pmapcar #'process-item items))"
  `(let ((lparallel:*kernel* (ensure-parallel-kernel
                               ,@(when worker-count
                                   `(:worker-count ,worker-count)))))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; Parallel ESI operations
;;; ---------------------------------------------------------------------------

(defun parallel-fetch (engine paths &key params
                                          character-id
                                          (priority +priority-normal+)
                                          (timeout 60)
                                          (chunk-size nil)
                                          progress-callback)
  "Fetch multiple ESI endpoints in parallel using lparallel.

Uses lparallel:pmapcar to dispatch requests across the parallel kernel's
worker threads, with each request going through the concurrent engine's
rate-limited pipeline.

ENGINE: A concurrent-engine (for rate-limited HTTP)
PATHS: List of ESI endpoint paths to fetch
PARAMS: Shared request parameters plist
CHARACTER-ID: Optional character ID for all requests
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout in seconds (default: 60)
CHUNK-SIZE: How many paths per parallel batch (default: auto-tuned)
PROGRESS-CALLBACK: Optional function (completed total) called per completion

Returns a list of results in the same order as PATHS. Each result is either:
  - An esi-response struct (on success)
  - A condition object (on failure)
  - NIL (on timeout)

Example:
  (parallel-fetch engine
    (list \"/v5/characters/95465499/\"
          \"/v5/characters/96071137/\"
          \"/v5/status/\"))"
  (when (null paths)
    (return-from parallel-fetch nil))
  (let* ((total (length paths))
         (actual-chunk (or chunk-size (compute-chunk-size total :io-bound)))
         (completed (make-atomic-counter))
         (chunks (partition-list paths actual-chunk)))
    (with-parallel-kernel ()
      ;; Process chunks in parallel, each chunk sequentially within its worker
      (let ((chunk-results
              (lparallel:pmapcar
               (lambda (chunk)
                 (mapcar (lambda (path)
                           (let ((result
                                   (handler-case
                                       (submit-and-wait engine path
                                                         :method :get
                                                         :priority priority
                                                         :params params
                                                         :character-id character-id
                                                         :timeout timeout)
                                     (error (e) e))))
                             (when progress-callback
                               (funcall progress-callback
                                        (atomic-counter-increment completed)
                                        total))
                             result))
                         chunk))
               chunks)))
        ;; Flatten chunk results back into a single list
        (apply #'append chunk-results)))))

(defun parallel-map-ids (engine path-template ids &key params
                                                        character-id
                                                        (priority +priority-normal+)
                                                        (timeout 60)
                                                        progress-callback)
  "Apply a path template to a list of IDs and fetch all in parallel.

ENGINE: A concurrent-engine
PATH-TEMPLATE: Format string with ~A for ID (e.g., \"/v5/characters/~A/\")
IDS: List of IDs to substitute
PARAMS: Shared request parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout (default: 60)
PROGRESS-CALLBACK: Optional function (completed total)

Returns an alist of (id . response-body) pairs. Failed requests have NIL as cdr.

Example:
  (parallel-map-ids engine \"/v5/characters/~A/\"
    '(95465499 96071137 1234567))"
  (let* ((paths (mapcar (lambda (id) (format nil path-template id)) ids))
         (results (parallel-fetch engine paths
                                   :params params
                                   :character-id character-id
                                   :priority priority
                                   :timeout timeout
                                   :progress-callback progress-callback)))
    (mapcar (lambda (id result)
              (cons id (when (esi-response-p result)
                         (esi-response-body result))))
            ids results)))

(defun parallel-fetch-all-pages (engine path &key params
                                                   character-id
                                                   (priority +priority-normal+)
                                                   (timeout 120)
                                                   (max-pages 100))
  "Fetch all pages of a paginated endpoint using parallel page fetching.

Like FETCH-ALL-PAGES but uses lparallel for parallel page dispatch after
determining the total page count from the first page.

ENGINE: A concurrent-engine
PATH: ESI endpoint path
PARAMS: Base query parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-page timeout (default: 120)
MAX-PAGES: Safety limit (default: 100)

Returns a list of all result data concatenated across pages."
  ;; Fetch page 1 to learn total page count
  (let* ((page1-params (append-query-param params "page" "1"))
         (page1-response (submit-and-wait engine path
                                           :params page1-params
                                           :character-id character-id
                                           :priority priority
                                           :timeout timeout)))
    (unless page1-response
      (return-from parallel-fetch-all-pages nil))
    (let* ((headers (esi-response-headers page1-response))
           (total-pages (or (parse-header-integer headers "x-pages") 1))
           (clamped-pages (min total-pages max-pages))
           (page1-data (esi-response-body page1-response)))
      (if (<= clamped-pages 1)
          ;; Single page
          (ensure-list-result page1-data)
          ;; Multiple pages — fetch remaining in parallel
          (let* ((remaining-paths
                   (loop for page from 2 to clamped-pages
                         collect path))
                 (remaining-params
                   (loop for page from 2 to clamped-pages
                         collect (append-query-param
                                   params "page"
                                   (princ-to-string page))))
                 ;; Use parallel-fetch with per-request params
                 (remaining-results
                   (with-parallel-kernel ()
                     (lparallel:pmapcar
                      (lambda (rpath rparams)
                        (handler-case
                            (submit-and-wait engine rpath
                                              :params rparams
                                              :character-id character-id
                                              :priority priority
                                              :timeout timeout)
                          (error () nil)))
                      remaining-paths remaining-params))))
            ;; Aggregate all page data
            (let ((all-data (ensure-list-result page1-data)))
              (dolist (result remaining-results)
                (when (esi-response-p result)
                  (let ((data (esi-response-body result)))
                    (when data
                      (setf all-data
                            (nconc all-data (ensure-list-result data)))))))
              all-data))))))

;;; ---------------------------------------------------------------------------
;;; Request deduplication
;;; ---------------------------------------------------------------------------

(defstruct (dedup-cache (:constructor %make-dedup-cache))
  "Cache for deduplicating identical concurrent requests.

When multiple parallel operations request the same endpoint with the same
parameters, only one actual HTTP request is made and the result is shared.

Slots:
  LOCK: Thread synchronization lock
  PENDING: Hash-table of cache-key -> (promise . waiters-count)
  STATS-LOCK: Lock for statistics
  TOTAL-REQUESTS: Total requests seen
  TOTAL-DEDUPED: Requests served from dedup cache"
  (lock (bt:make-lock "dedup-cache-lock"))
  (pending (make-hash-table :test 'equal) :type hash-table)
  (stats-lock (bt:make-lock "dedup-stats-lock"))
  (total-requests 0 :type (integer 0))
  (total-deduped 0 :type (integer 0)))

(defun make-dedup-cache ()
  "Create a new request deduplication cache."
  (%make-dedup-cache))

(defvar *dedup-cache* nil
  "Global request deduplication cache. Set by INITIALIZE-DEDUP-CACHE.")

(defun initialize-dedup-cache ()
  "Initialize the global deduplication cache."
  (setf *dedup-cache* (make-dedup-cache)))

(defun make-dedup-key (path method params)
  "Generate a deduplication key for a request.

PATH: ESI endpoint path
METHOD: HTTP method keyword
PARAMS: Request parameters plist

Returns a string key."
  (format nil "~A:~A:~S" method path
          (sort (copy-list (or (getf params :query-params) nil))
                #'string< :key #'car)))

(defun dedup-fetch (engine path &key (method :get)
                                       params
                                       character-id
                                       (priority +priority-normal+)
                                       (timeout 60)
                                       (dedup-cache *dedup-cache*))
  "Fetch an ESI endpoint with request deduplication.

If an identical request (same path, method, params) is already in flight,
waits for that request's result instead of making a duplicate HTTP call.

ENGINE: A concurrent-engine
PATH: ESI endpoint path
METHOD: HTTP method (default: :get)
PARAMS: Request parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Timeout in seconds (default: 60)
DEDUP-CACHE: Dedup cache to use (default: *dedup-cache*)

Returns the esi-response or NIL."
  (unless dedup-cache
    ;; No dedup cache — fall through to direct request
    (return-from dedup-fetch
      (submit-and-wait engine path
                        :method method
                        :priority priority
                        :params params
                        :character-id character-id
                        :timeout timeout)))
  (let ((key (make-dedup-key path method params)))
    (bt:with-lock-held ((dedup-cache-stats-lock dedup-cache))
      (incf (dedup-cache-total-requests dedup-cache)))
    ;; Check if request is already in flight
    (bt:with-lock-held ((dedup-cache-lock dedup-cache))
      (let ((existing (gethash key (dedup-cache-pending dedup-cache))))
        (when existing
          ;; Another thread is already fetching this — wait on its result
          (bt:with-lock-held ((dedup-cache-stats-lock dedup-cache))
            (incf (dedup-cache-total-deduped dedup-cache)))
          (let ((request (car existing)))
            ;; Release the dedup lock and wait
            (return-from dedup-fetch
              (wait-for-request request :timeout timeout))))))
    ;; No existing request — create one and register it
    (let ((request (submit-request engine path
                                    :method method
                                    :priority priority
                                    :params params
                                    :character-id character-id
                                    :timeout timeout)))
      (bt:with-lock-held ((dedup-cache-lock dedup-cache))
        (setf (gethash key (dedup-cache-pending dedup-cache))
              (cons request 1)))
      ;; Wait for the result
      (unwind-protect
           (wait-for-request request :timeout timeout)
        ;; Remove from pending on completion
        (bt:with-lock-held ((dedup-cache-lock dedup-cache))
          (remhash key (dedup-cache-pending dedup-cache)))))))

(defun dedup-statistics (&optional (cache *dedup-cache*))
  "Return deduplication statistics as a plist.

Returns:
  :TOTAL-REQUESTS — total requests seen
  :TOTAL-DEDUPED — requests served from dedup
  :DEDUP-RATE — fraction of deduplicated requests
  :PENDING — number of currently in-flight deduplicated requests"
  (when cache
    (bt:with-lock-held ((dedup-cache-stats-lock cache))
      (let ((total (dedup-cache-total-requests cache))
            (deduped (dedup-cache-total-deduped cache)))
        (list :total-requests total
              :total-deduped deduped
              :dedup-rate (if (plusp total)
                              (/ (float deduped) total)
                              0.0)
              :pending (hash-table-count (dedup-cache-pending cache)))))))

;;; ---------------------------------------------------------------------------
;;; Chunk size computation
;;; ---------------------------------------------------------------------------

(defun compute-chunk-size (total-items operation-type)
  "Compute optimal chunk size for parallel partitioning.

TOTAL-ITEMS: Total number of items to process
OPERATION-TYPE: :IO-BOUND or :CPU-BOUND

For I/O-bound work (ESI requests), we want many small chunks to keep all
workers busy despite variable latency. For CPU-bound work, fewer larger
chunks minimize overhead.

Returns an integer chunk size."
  (let ((workers (if *parallel-kernel*
                     (let ((lparallel:*kernel* *parallel-kernel*))
                       (lparallel:kernel-worker-count))
                     (default-worker-count))))
    (ecase operation-type
      (:io-bound
       ;; For I/O: aim for 2-4 chunks per worker to balance load
       (max 1 (ceiling total-items (* workers 3))))
      (:cpu-bound
       ;; For CPU: one chunk per worker is optimal
       (max 1 (ceiling total-items workers))))))

;;; ---------------------------------------------------------------------------
;;; Utility functions
;;; ---------------------------------------------------------------------------

(defun partition-list (list chunk-size)
  "Partition LIST into sublists of at most CHUNK-SIZE elements.

LIST: The list to partition
CHUNK-SIZE: Maximum elements per sublist

Returns a list of sublists."
  (loop for rest on list by (lambda (l) (nthcdr chunk-size l))
        collect (subseq rest 0 (min chunk-size (length rest)))))

(defun ensure-list-result (data)
  "Ensure DATA is a list. If it's a vector, coerce it. If scalar, wrap it.

DATA: Any value from an ESI response body

Returns a list."
  (cond
    ((listp data) data)
    ((vectorp data) (coerce data 'list))
    ((null data) nil)
    (t (list data))))

;;; ---------------------------------------------------------------------------
;;; Atomic counter (thread-safe counter for progress tracking)
;;; ---------------------------------------------------------------------------

(defstruct (atomic-counter (:constructor make-atomic-counter))
  "Thread-safe integer counter.

Slots:
  LOCK: Thread synchronization lock
  VALUE: Current counter value"
  (lock (bt:make-lock "atomic-counter-lock"))
  (value 0 :type integer))

(defun atomic-counter-increment (counter)
  "Atomically increment COUNTER and return the new value."
  (bt:with-lock-held ((atomic-counter-lock counter))
    (incf (atomic-counter-value counter))))

(defun atomic-counter-value-of (counter)
  "Return the current value of COUNTER. Thread-safe."
  (bt:with-lock-held ((atomic-counter-lock counter))
    (atomic-counter-value counter)))
