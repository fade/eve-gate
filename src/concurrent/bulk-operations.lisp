;;;; bulk-operations.lisp - High-level bulk ESI operations for eve-gate
;;;;
;;;; Provides convenience functions for common bulk data retrieval patterns
;;;; in EVE Online applications. These operations combine the concurrent
;;;; engine with parallel execution and request deduplication.
;;;;
;;;; Patterns supported:
;;;;   - bulk-get: Fetch multiple endpoints concurrently
;;;;   - bulk-post: Submit multiple POST requests concurrently
;;;;   - bulk-process: Apply a function to each result as it completes
;;;;   - with-bulk-processing: Macro for scoped bulk operations
;;;;   - Paginated bulk: Fetch all pages of multiple endpoints
;;;;   - ID expansion: Fetch full records for a list of IDs
;;;;
;;;; All operations respect rate limits, handle errors per-request, and
;;;; provide progress tracking.

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Bulk GET operations
;;; ---------------------------------------------------------------------------

(defun bulk-get (engine-or-client paths &key params
                                              character-id
                                              (priority +priority-normal+)
                                              (timeout 60)
                                              (parallel t)
                                              progress-callback)
  "Fetch multiple ESI endpoints concurrently.

ENGINE-OR-CLIENT: A concurrent-engine or an object with an engine accessor
PATHS: List of ESI endpoint path strings
PARAMS: Shared parameters for all requests
CHARACTER-ID: Optional character ID for authenticated requests
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout in seconds (default: 60)
PARALLEL: If T (default), use lparallel for parallel dispatch
PROGRESS-CALLBACK: Optional function (completed total) called per completion

Returns a list of results, one per path, in order. Each result is:
  - Parsed response body (hash-table, vector, etc.) on success
  - NIL on failure or timeout

Example:
  ;; Fetch multiple character profiles
  (bulk-get engine
    (list \"/v5/characters/95465499/\"
          \"/v5/characters/96071137/\"))"
  (let ((eng (resolve-engine engine-or-client)))
    (if parallel
        ;; Use lparallel parallel fetch
        (let ((results (parallel-fetch eng paths
                                        :params params
                                        :character-id character-id
                                        :priority priority
                                        :timeout timeout
                                        :progress-callback progress-callback)))
          (mapcar (lambda (r)
                    (when (esi-response-p r)
                      (esi-response-body r)))
                  results))
        ;; Use engine bulk submit (serial within worker pool)
        (let* ((specs (mapcar (lambda (path)
                                (list :path path
                                      :params params
                                      :character-id character-id))
                              paths))
               (results (bulk-submit-and-wait eng specs
                                               :priority priority
                                               :timeout timeout
                                               :progress-callback progress-callback)))
          (mapcar (lambda (r)
                    (when (esi-response-p r)
                      (esi-response-body r)))
                  results)))))

;;; ---------------------------------------------------------------------------
;;; Bulk POST operations
;;; ---------------------------------------------------------------------------

(defun bulk-post (engine paths-and-bodies &key character-id
                                                (priority +priority-normal+)
                                                (timeout 60)
                                                progress-callback)
  "Submit multiple POST requests concurrently.

ENGINE: A concurrent-engine
PATHS-AND-BODIES: List of (path . body) pairs, where:
  PATH is an ESI endpoint path string
  BODY is the request body (will be JSON-encoded if a hash-table or list)
CHARACTER-ID: Optional character ID for authenticated requests
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout in seconds (default: 60)
PROGRESS-CALLBACK: Optional function (completed total) called per completion

Returns a list of results in order.

Example:
  (bulk-post engine
    (list (cons \"/v1/characters/affiliation/\"
                #(95465499 96071137))))"
  (let* ((specs (mapcar (lambda (pair)
                          (list :path (car pair)
                                :method :post
                                :params (list :content (cdr pair))
                                :character-id character-id))
                        paths-and-bodies))
         (results (bulk-submit-and-wait engine specs
                                         :priority priority
                                         :timeout timeout
                                         :progress-callback progress-callback)))
    (mapcar (lambda (r)
              (when (esi-response-p r)
                (esi-response-body r)))
            results)))

;;; ---------------------------------------------------------------------------
;;; Bulk processing with per-result callback
;;; ---------------------------------------------------------------------------

(defun bulk-process (engine paths processor &key params
                                                  character-id
                                                  (priority +priority-normal+)
                                                  (timeout 60)
                                                  (parallel t)
                                                  error-handler)
  "Fetch multiple endpoints and apply PROCESSOR to each result.

Unlike bulk-get which collects all results, bulk-process calls PROCESSOR
as each result arrives. This is useful for streaming processing of large
result sets without holding all data in memory.

ENGINE: A concurrent-engine
PATHS: List of ESI endpoint paths
PROCESSOR: Function (path response-body) called for each success
PARAMS: Shared request parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout (default: 60)
PARALLEL: Use lparallel (default: T)
ERROR-HANDLER: Optional function (path condition) for errors

Returns the number of successfully processed results.

Example:
  ;; Process character profiles as they arrive
  (bulk-process engine character-paths
    (lambda (path body)
      (store-character-data (extract-id path) body)))"
  (let* ((eng (resolve-engine engine))
         (processed-count 0))
    (if parallel
        ;; Parallel processing
        (with-parallel-kernel ()
          (lparallel:pmapcar
           (lambda (path)
             (handler-case
                 (let ((response (submit-and-wait eng path
                                                    :params params
                                                    :character-id character-id
                                                    :priority priority
                                                    :timeout timeout)))
                   (when (esi-response-p response)
                     (funcall processor path (esi-response-body response))
                     (bt:with-lock-held (*parallel-kernel-lock*)
                       (incf processed-count))))
               (error (e)
                 (when error-handler
                   (funcall error-handler path e)))))
           paths))
        ;; Sequential processing via engine
        (let* ((specs (mapcar (lambda (path)
                                (list :path path
                                      :params params
                                      :character-id character-id))
                              paths))
               (requests (bulk-submit eng specs
                                       :priority priority
                                       :timeout timeout)))
          (loop for path in paths
                for request in requests
                do (multiple-value-bind (result success-p)
                       (wait-for-request request :timeout timeout)
                     (cond
                       ((and success-p (esi-response-p result))
                        (handler-case
                            (progn
                              (funcall processor path (esi-response-body result))
                              (incf processed-count))
                          (error (e)
                            (when error-handler
                              (funcall error-handler path e)))))
                       (error-handler
                        (funcall error-handler path
                                 (if (typep result 'condition)
                                     result
                                     (make-condition 'simple-error
                                                      :format-control "Request failed or timed out")))))))))
    processed-count))

;;; ---------------------------------------------------------------------------
;;; Scoped bulk processing
;;; ---------------------------------------------------------------------------

(defmacro with-bulk-processing ((engine &key (parallel t)
                                              (priority '+priority-normal+)
                                              (timeout 60))
                                 &body body)
  "Execute BODY with a bulk processing context.

Provides a local function BULK-FETCH within BODY that collects paths
and executes them all at once when the form completes.

ENGINE: A concurrent-engine (evaluated once)
PARALLEL: Use lparallel (default: T)
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout (default: 60)

Within BODY, the following functions are available:
  (ENQUEUE path &key params) — Queue a path for bulk fetching
  (RESULTS) — Return all results collected so far (empty until form completes)

Example:
  (with-bulk-processing (engine)
    (enqueue \"/v5/characters/95465499/\")
    (enqueue \"/v5/characters/96071137/\")
    (enqueue \"/v5/status/\")
    (results))"
  (let ((eng-var (gensym "ENGINE"))
        (paths-var (gensym "PATHS"))
        (params-var (gensym "PARAMS"))
        (results-var (gensym "RESULTS")))
    `(let ((,eng-var ,engine)
           (,paths-var '())
           (,params-var '())
           (,results-var nil))
       (flet ((enqueue (path &key params)
                (push path ,paths-var)
                (push params ,params-var))
              (results ()
                (unless ,results-var
                  (setf ,results-var
                        (bulk-get ,eng-var (nreverse ,paths-var)
                                  :priority ,priority
                                  :timeout ,timeout
                                  :parallel ,parallel)))
                ,results-var))
         ,@body
         ;; Auto-execute if results weren't explicitly requested
         (unless ,results-var
           (setf ,results-var
                 (bulk-get ,eng-var (nreverse ,paths-var)
                           :priority ,priority
                           :timeout ,timeout
                           :parallel ,parallel)))
         ,results-var))))

;;; ---------------------------------------------------------------------------
;;; Specialized bulk patterns for EVE Online
;;; ---------------------------------------------------------------------------

(defun bulk-expand-ids (engine path-template ids &key params
                                                       character-id
                                                       (priority +priority-normal+)
                                                       (timeout 60)
                                                       (parallel t)
                                                       progress-callback)
  "Expand a list of IDs into full records by fetching each.

ENGINE: A concurrent-engine
PATH-TEMPLATE: Format string with ~A for ID substitution
IDS: List of IDs to fetch
PARAMS: Shared request parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout (default: 60)
PARALLEL: Use lparallel (default: T)
PROGRESS-CALLBACK: Optional function (completed total)

Returns an alist of (id . body-data) pairs. Missing data has NIL cdr.

Example:
  ;; Expand type IDs to full type info
  (bulk-expand-ids engine \"/v3/universe/types/~A/\"
    '(34 35 36 37))"
  (let* ((paths (mapcar (lambda (id) (format nil path-template id)) ids))
         (results (bulk-get engine paths
                            :params params
                            :character-id character-id
                            :priority priority
                            :timeout timeout
                            :parallel parallel
                            :progress-callback progress-callback)))
    (mapcar #'cons ids results)))

(defun bulk-fetch-paginated (engine paths &key params
                                               character-id
                                               (priority +priority-normal+)
                                               (timeout 120)
                                               (max-pages 100))
  "Fetch all pages of multiple paginated endpoints.

Each path gets its full page set fetched. Results are aggregated per path.

ENGINE: A concurrent-engine
PATHS: List of ESI endpoint paths (each may be paginated)
PARAMS: Shared base parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-page timeout (default: 120)
MAX-PAGES: Safety limit per endpoint (default: 100)

Returns an alist of (path . aggregated-data) pairs."
  (with-parallel-kernel ()
    (lparallel:pmapcar
     (lambda (path)
       (cons path
             (handler-case
                 (parallel-fetch-all-pages engine path
                                            :params params
                                            :character-id character-id
                                            :priority priority
                                            :timeout timeout
                                            :max-pages max-pages)
               (error () nil))))
     paths)))

;;; ---------------------------------------------------------------------------
;;; Engine resolution helper
;;; ---------------------------------------------------------------------------

(defun resolve-engine (engine-or-client)
  "Resolve ENGINE-OR-CLIENT to a concurrent-engine.

Accepts a concurrent-engine directly, or any object that has a method
to extract one."
  (etypecase engine-or-client
    (concurrent-engine engine-or-client)))
