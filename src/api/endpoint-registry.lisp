;;;; endpoint-registry.lisp - Runtime endpoint registry for ESI API metadata
;;;;
;;;; Provides runtime lookup and query facilities for ESI endpoint metadata.
;;;; The registry is populated at load time by the generated file
;;;; endpoint-registry-data.lisp, which contains metadata for all 195 ESI endpoints.
;;;;
;;;; The registry enables:
;;;;   - Looking up endpoint metadata by operation ID at runtime
;;;;   - Querying endpoints by category, method, auth requirements
;;;;   - Providing introspection for REPL-driven development
;;;;   - Supporting the API client's routing and middleware decisions
;;;;
;;;; Design:
;;;;   - Hash-table based for O(1) lookup by operation ID
;;;;   - Populated lazily (on first access) or explicitly
;;;;   - Thread-safe reads (populated once, then read-only)
;;;;   - Separate from generated code - hand-written infrastructure
;;;;
;;;; Usage:
;;;;   (populate-endpoint-registry)  ; called by generated code at load time
;;;;   (lookup-endpoint "get_characters_character_id")
;;;;   (list-endpoints-by-category "markets")

(in-package #:eve-gate.api)

;;; ---------------------------------------------------------------------------
;;; Registry infrastructure
;;; ---------------------------------------------------------------------------

;; Forward declaration of the endpoint registry hash-table.
;; The actual population happens in the generated file endpoint-registry-data.lisp
;; which defines populate-endpoint-registry to fill this table.
(defvar *endpoint-registry* (make-hash-table :test 'equal)
  "Registry mapping operation IDs to endpoint metadata plists.
Each entry contains: :path, :method, :category, :requires-auth, :scopes,
:paginated, :cache-duration, :function-name, :deprecated.

Populated by the generated populate-endpoint-registry function.")

(defun register-endpoint (operation-id metadata)
  "Register a single endpoint's metadata in the registry.

OPERATION-ID: String operation ID (e.g., \"get_characters_character_id\")
METADATA: Plist of endpoint metadata

Returns METADATA."
  (when (and (boundp '*endpoint-registry*)
             (hash-table-p *endpoint-registry*))
    (setf (gethash operation-id *endpoint-registry*) metadata))
  metadata)

(defun find-endpoint (operation-id)
  "Find endpoint metadata by operation ID. Alias for lookup-endpoint.

OPERATION-ID: String operation ID

Returns a plist of metadata, or NIL."
  (when (and (boundp '*endpoint-registry*)
             (hash-table-p *endpoint-registry*))
    (gethash operation-id *endpoint-registry*)))

(defun list-endpoints (&key category method requires-auth)
  "List endpoint operation IDs with optional filtering.

CATEGORY: Filter by category string (e.g., \"characters\")
METHOD: Filter by HTTP method keyword (:GET, :POST, etc.)
REQUIRES-AUTH: When T, only authenticated endpoints; when NIL, only public

Returns a list of operation ID strings matching the filters."
  (unless (and (boundp '*endpoint-registry*)
               (hash-table-p *endpoint-registry*))
    (return-from list-endpoints nil))
  (let ((results '()))
    (maphash
     (lambda (op-id meta)
       (let ((match t))
         (when (and category
                    (not (string-equal (getf meta :category) category)))
           (setf match nil))
         (when (and method
                    (not (eq (getf meta :method) method)))
           (setf match nil))
         (when (and requires-auth
                    (not (getf meta :requires-auth)))
           (setf match nil))
         (when match
           (push op-id results))))
     *endpoint-registry*)
    (sort results #'string<)))

(defun endpoint-count ()
  "Return the total number of registered endpoints."
  (if (and (boundp '*endpoint-registry*)
           (hash-table-p *endpoint-registry*))
      (hash-table-count *endpoint-registry*)
      0))

(defun endpoint-categories ()
  "Return a sorted list of all endpoint categories in the registry."
  (unless (and (boundp '*endpoint-registry*)
               (hash-table-p *endpoint-registry*))
    (return-from endpoint-categories nil))
  (let ((categories (make-hash-table :test 'equal)))
    (maphash
     (lambda (op-id meta)
       (declare (ignore op-id))
       (when-let ((cat (getf meta :category)))
         (setf (gethash cat categories) t)))
     *endpoint-registry*)
    (sort (loop for cat being the hash-keys of categories collect cat)
          #'string<)))

(defun endpoint-function-name (operation-id)
  "Look up the Lisp function name for an endpoint operation ID.

OPERATION-ID: String operation ID

Returns the function name string, or NIL."
  (when-let ((meta (find-endpoint operation-id)))
    (getf meta :function-name)))

(defun endpoint-requires-auth-p (operation-id)
  "Check whether an endpoint requires authentication.

OPERATION-ID: String operation ID

Returns T if authentication is required, NIL otherwise."
  (when-let ((meta (find-endpoint operation-id)))
    (getf meta :requires-auth)))

(defun endpoint-scopes (operation-id)
  "Return the OAuth scopes required for an endpoint.

OPERATION-ID: String operation ID

Returns a list of scope strings, or NIL for public endpoints."
  (when-let ((meta (find-endpoint operation-id)))
    (getf meta :scopes)))

(defun endpoint-paginated-p (operation-id)
  "Check whether an endpoint supports pagination.

OPERATION-ID: String operation ID (not to be confused with the identically named
function in spec-processor.lisp that operates on response hash-tables)

Returns T if the endpoint is paginated, NIL otherwise."
  (when-let ((meta (find-endpoint operation-id)))
    (getf meta :paginated)))

(defun endpoint-cache-duration (operation-id)
  "Return the cache duration in seconds for an endpoint.

OPERATION-ID: String operation ID

Returns an integer (seconds), or NIL if no caching info."
  (when-let ((meta (find-endpoint operation-id)))
    (getf meta :cache-duration)))

(defun endpoint-deprecated-p (operation-id)
  "Check whether an endpoint is deprecated.

OPERATION-ID: String operation ID

Returns T if deprecated, NIL otherwise."
  (when-let ((meta (find-endpoint operation-id)))
    (getf meta :deprecated)))

(defun print-endpoint-summary (operation-id &optional (stream *standard-output*))
  "Print a human-readable summary of an endpoint.

OPERATION-ID: String operation ID
STREAM: Output stream (default: *standard-output*)

Example:
  (print-endpoint-summary \"get_characters_character_id\")"
  (let ((meta (find-endpoint operation-id)))
    (if meta
        (progn
          (format stream "~&Endpoint: ~A~%" operation-id)
          (format stream "  Function: ~A~%" (getf meta :function-name))
          (format stream "  Method: ~A~%" (getf meta :method))
          (format stream "  Path: ~A~%" (getf meta :path))
          (format stream "  Category: ~A~%" (getf meta :category))
          (format stream "  Auth Required: ~A~%" (getf meta :requires-auth))
          (when (getf meta :scopes)
            (format stream "  Scopes: ~{~A~^, ~}~%" (getf meta :scopes)))
          (format stream "  Paginated: ~A~%" (getf meta :paginated))
          (when (getf meta :cache-duration)
            (format stream "  Cache Duration: ~D seconds~%" (getf meta :cache-duration)))
          (when (getf meta :deprecated)
            (format stream "  DEPRECATED~%")))
        (format stream "~&Endpoint ~S not found in registry.~%" operation-id)))
  (values))

(defun registry-summary (&optional (stream *standard-output*))
  "Print a summary of the endpoint registry.

STREAM: Output stream (default: *standard-output*)"
  (format stream "~&Endpoint Registry Summary~%")
  (format stream "~A~%" (make-string 40 :initial-element #\=))
  (format stream "Total endpoints: ~D~%" (endpoint-count))
  (let ((categories (endpoint-categories)))
    (format stream "Categories (~D):~%" (length categories))
    (dolist (cat categories)
      (let ((count (length (list-endpoints :category cat))))
        (format stream "  ~A: ~D endpoints~%" cat count))))
  ;; Method breakdown
  (dolist (method '(:get :post :put :delete))
    (let ((count (length (list-endpoints :method method))))
      (when (> count 0)
        (format stream "~A: ~D endpoints~%" method count))))
  ;; Auth breakdown
  (let ((auth-count (length (list-endpoints :requires-auth t))))
    (format stream "Authenticated: ~D endpoints~%" auth-count))
  (values))
