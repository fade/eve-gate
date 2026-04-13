;;;; spec-processor.lisp - ESI OpenAPI specification download, parsing, and processing
;;;;
;;;; Downloads the EVE Swagger Interface (ESI) OpenAPI 2.0 specification,
;;;; parses it into structured Common Lisp data, and extracts:
;;;;   - Endpoint definitions with methods, parameters, and response schemas
;;;;   - Global parameter definitions (shared across endpoints)
;;;;   - Security requirements (OAuth scopes per endpoint)
;;;;   - Caching metadata (cache duration from descriptions)
;;;;   - Alternate route/version information
;;;;
;;;; The processed spec is stored in an esi-spec struct which serves as the
;;;; single source of truth for the code generation framework in Phase 2 Task 2.
;;;;
;;;; Design:
;;;;   - Pure parsing functions operate on jzon hash-tables
;;;;   - I/O is confined to download-esi-spec and load-cached-spec
;;;;   - All extracted data is immutable after processing
;;;;   - Supports multiple spec versions (latest, _latest, etc.)
;;;;
;;;; Usage:
;;;;   (defvar *spec* (fetch-and-process-esi-spec))
;;;;   (esi-spec-endpoints *spec*)         ; all endpoint definitions
;;;;   (esi-spec-version *spec*)           ; spec version string
;;;;   (find-endpoint *spec* "get_characters_character_id")

(in-package #:eve-gate.api)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *esi-spec-url* "https://esi.evetech.net/latest/swagger.json"
  "URL to download the latest ESI OpenAPI specification.")

(defparameter *esi-spec-versions*
  '(("latest" . "https://esi.evetech.net/latest/swagger.json")
    ("_latest" . "https://esi.evetech.net/_latest/swagger.json"))
  "Available ESI specification versions with their URLs.
The 'latest' version is the stable production version.
The '_latest' version may include newer experimental endpoints.")

(defparameter *spec-cache-directory* nil
  "Directory for caching downloaded spec files. NIL means use *default-pathname-defaults*.
Set to a specific path for persistent caching across sessions.")

(defparameter *spec-cache-ttl* 86400
  "Time-to-live for cached spec files in seconds (default: 24 hours).
The ESI spec changes infrequently, so daily updates are sufficient.")

;;; ---------------------------------------------------------------------------
;;; ESI Specification structure
;;; ---------------------------------------------------------------------------

(defstruct (esi-spec (:constructor %make-esi-spec)
                     (:print-function print-esi-spec))
  "Represents a fully processed ESI OpenAPI specification.

This is the primary data structure consumed by the code generation framework.
It contains all information needed to generate API client functions.

Slots:
  TITLE: Spec title (e.g., \"EVE Swagger Interface\")
  VERSION: Spec version string (e.g., \"1.36\")
  BASE-PATH: API base path (e.g., \"/latest\")
  HOST: API host (e.g., \"esi.evetech.net\")
  SCHEMES: List of supported schemes (e.g., (\"https\"))
  ENDPOINTS: List of endpoint-definition structs
  GLOBAL-PARAMETERS: Hash-table of shared parameter definitions
  SECURITY-DEFINITIONS: Hash-table of security scheme definitions (OAuth scopes)
  CATEGORIES: List of endpoint category strings (e.g., \"characters\", \"markets\")
  RAW-SPEC: The original parsed JSON hash-table (for reference)
  FETCHED-AT: Universal time when the spec was downloaded
  SOURCE-URL: URL the spec was fetched from"
  (title nil :type (or null string))
  (version nil :type (or null string))
  (base-path nil :type (or null string))
  (host nil :type (or null string))
  (schemes nil :type list)
  (endpoints nil :type list)
  (global-parameters nil :type (or null hash-table))
  (security-definitions nil :type (or null hash-table))
  (categories nil :type list)
  (raw-spec nil :type (or null hash-table))
  (fetched-at 0 :type integer)
  (source-url nil :type (or null string)))

(defun print-esi-spec (spec stream depth)
  "Print an esi-spec in a human-readable format."
  (declare (ignore depth))
  (print-unreadable-object (spec stream :type t)
    (format stream "~A v~A (~D endpoints, ~D categories)"
            (or (esi-spec-title spec) "Unknown")
            (or (esi-spec-version spec) "?")
            (length (esi-spec-endpoints spec))
            (length (esi-spec-categories spec)))))

;;; ---------------------------------------------------------------------------
;;; Endpoint definition structure
;;; ---------------------------------------------------------------------------

(defstruct (endpoint-definition (:constructor make-endpoint-definition)
                                (:print-function print-endpoint-definition))
  "Represents a single ESI API endpoint with all metadata needed for code generation.

Slots:
  OPERATION-ID: Unique identifier (e.g., \"get_characters_character_id\")
  FUNCTION-NAME: Lispified function name (e.g., \"get-characters-character-id\")
  PATH: URL path template (e.g., \"/characters/{character_id}/\")
  METHOD: HTTP method keyword (:GET :POST :PUT :DELETE)
  DESCRIPTION: Full description text from the spec
  SUMMARY: Brief summary (first line of description)
  CATEGORY: Endpoint category (e.g., \"characters\", \"markets\")
  PARAMETERS: List of parameter-definition structs
  PATH-PARAMETERS: Subset of parameters that are path parameters
  QUERY-PARAMETERS: Subset of parameters that are query parameters
  HEADER-PARAMETERS: Subset of parameters that are header parameters
  BODY-PARAMETER: The body parameter (for POST/PUT), or NIL
  RESPONSE-SCHEMA: Schema-definition for the 200 response
  RESPONSE-DESCRIPTION: Description of the 200 response
  REQUIRES-AUTH-P: Whether the endpoint requires OAuth authentication
  REQUIRED-SCOPES: List of required OAuth scope strings
  CACHE-DURATION: Cache time in seconds extracted from description
  PAGINATED-P: Whether the endpoint supports pagination (X-Pages header)
  ALTERNATE-ROUTES: List of alternate route path strings
  DEPRECATED-P: Whether the endpoint is deprecated
  TAGS: List of tag strings from the spec"
  (operation-id nil :type (or null string))
  (function-name nil :type (or null string))
  (path nil :type (or null string))
  (method nil :type (or null keyword))
  (description nil :type (or null string))
  (summary nil :type (or null string))
  (category nil :type (or null string))
  (parameters nil :type list)
  (path-parameters nil :type list)
  (query-parameters nil :type list)
  (header-parameters nil :type list)
  (body-parameter nil)
  (response-schema nil)
  (response-description nil :type (or null string))
  (requires-auth-p nil :type boolean)
  (required-scopes nil :type list)
  (cache-duration nil :type (or null integer))
  (paginated-p nil :type boolean)
  (alternate-routes nil :type list)
  (deprecated-p nil :type boolean)
  (tags nil :type list))

(defun print-endpoint-definition (endpoint stream depth)
  "Print an endpoint-definition in a readable format."
  (declare (ignore depth))
  (print-unreadable-object (endpoint stream :type t)
    (format stream "~A ~A ~A~@[ (~{~A~^,~})~]"
            (endpoint-definition-method endpoint)
            (endpoint-definition-path endpoint)
            (endpoint-definition-operation-id endpoint)
            (endpoint-definition-required-scopes endpoint))))

;;; ---------------------------------------------------------------------------
;;; Parameter definition structure
;;; ---------------------------------------------------------------------------

(defstruct (parameter-definition (:constructor make-parameter-definition)
                                 (:print-function print-parameter-definition))
  "Represents a single parameter for an ESI endpoint.

Slots:
  NAME: Parameter name as it appears in the API (e.g., \"character_id\")
  CL-NAME: Lispified parameter name (keyword, e.g., :CHARACTER-ID)
  LOCATION: Where the parameter goes (:path :query :header :body)
  REQUIRED-P: Whether the parameter is required
  DESCRIPTION: Human-readable description
  SCHEMA: Schema-definition for the parameter type
  DEFAULT-VALUE: Default value if any
  ENUM-VALUES: List of allowed values for enum parameters"
  (name nil :type (or null string))
  (cl-name nil)
  (location nil :type (or null keyword))
  (required-p nil :type boolean)
  (description nil :type (or null string))
  (schema nil :type (or null schema-definition))
  (default-value nil)
  (enum-values nil :type list))

(defun print-parameter-definition (param stream depth)
  "Print a parameter-definition in a readable format."
  (declare (ignore depth))
  (print-unreadable-object (param stream :type t)
    (format stream "~A ~A ~A~:[~; REQUIRED~]"
            (parameter-definition-name param)
            (parameter-definition-location param)
            (when (parameter-definition-schema param)
              (schema-definition-type (parameter-definition-schema param)))
            (parameter-definition-required-p param))))

;;; ---------------------------------------------------------------------------
;;; Spec downloading and caching
;;; ---------------------------------------------------------------------------

(defun download-esi-spec (&key (url *esi-spec-url*) (timeout 30))
  "Download the ESI OpenAPI specification from the given URL.

URL: URL to fetch the spec from (default: *esi-spec-url*)
TIMEOUT: HTTP request timeout in seconds (default: 30)

Returns the parsed JSON as a hash-table (via jzon).

Signals ESI-NETWORK-ERROR on connection failure."
  (log-info "Downloading ESI spec from ~A" url)
  (handler-case
      (multiple-value-bind (body status)
          (dex:request url
                       :method :get
                       :headers '(("Accept" . "application/json")
                                  ("User-Agent" . "eve-gate/0.1.0"))
                       :connect-timeout timeout
                       :read-timeout timeout
                       :force-string t)
        (unless (= status 200)
          (error 'esi-error
                 :status-code status
                 :message (format nil "Failed to download ESI spec: HTTP ~D" status)
                 :endpoint url))
        (let ((parsed (com.inuoe.jzon:parse body)))
          (log-info "ESI spec downloaded successfully (~D bytes)" (length body))
          parsed))
    (error (e)
      (log-error "Failed to download ESI spec from ~A: ~A" url e)
      (error 'esi-network-error
             :message (format nil "Failed to download ESI spec: ~A" e)
             :endpoint url
             :original-condition e))))

(defun spec-cache-path (&optional (version "latest"))
  "Return the filesystem path for caching a spec version.

VERSION: Spec version string (default: \"latest\")

Returns a pathname."
  (let ((cache-dir (or *spec-cache-directory*
                       (merge-pathnames ".tmp/" (asdf:system-source-directory :eve-gate)))))
    (ensure-directories-exist cache-dir)
    (merge-pathnames (format nil "esi-spec-~A.json" version) cache-dir)))

(defun save-spec-to-cache (spec-json &optional (version "latest"))
  "Save a downloaded spec JSON string to the local cache.

SPEC-JSON: The raw JSON string of the spec
VERSION: Spec version string for the cache filename

Returns the cache file pathname."
  (let ((cache-path (spec-cache-path version)))
    (with-open-file (out cache-path :direction :output
                                    :if-exists :supersede
                                    :if-does-not-exist :create)
      (write-string spec-json out))
    (log-debug "Spec cached to ~A" cache-path)
    cache-path))

(defun load-cached-spec (&optional (version "latest"))
  "Load a previously cached spec from disk, if it exists and is fresh.

VERSION: Spec version to load (default: \"latest\")

Returns two values:
  1. Parsed JSON hash-table, or NIL if cache is missing/stale
  2. T if loaded from cache, NIL otherwise"
  (let ((cache-path (spec-cache-path version)))
    (if (probe-file cache-path)
        (let* ((file-write-time (file-write-date cache-path))
               (age (- (get-universal-time) file-write-time)))
          (if (< age *spec-cache-ttl*)
              (handler-case
                  (let ((content (uiop:read-file-string cache-path)))
                    (values (com.inuoe.jzon:parse content) t))
                (error (e)
                  (log-warn "Failed to load cached spec: ~A" e)
                  (values nil nil)))
              (progn
                (log-debug "Cached spec expired (~D seconds old, TTL ~D)" age *spec-cache-ttl*)
                (values nil nil))))
        (values nil nil))))

;;; ---------------------------------------------------------------------------
;;; Spec processing - main entry point
;;; ---------------------------------------------------------------------------

(defun fetch-and-process-esi-spec (&key (version "latest")
                                        (use-cache t)
                                        (cache-result t)
                                        url)
  "Download (or load from cache) and fully process the ESI OpenAPI specification.

This is the primary entry point for the spec processing pipeline. It:
  1. Checks the local cache for a fresh copy
  2. Downloads from ESI if needed
  3. Parses all endpoints, parameters, and schemas
  4. Validates the processed spec
  5. Returns the complete esi-spec struct

VERSION: Spec version (\"latest\" or \"_latest\") (default: \"latest\")
USE-CACHE: Whether to check local cache first (default: T)
CACHE-RESULT: Whether to cache the downloaded spec (default: T)
URL: Override URL to download from (default: uses version to look up URL)

Returns an ESI-SPEC struct.

Example:
  ;; Normal usage - cache-aware
  (fetch-and-process-esi-spec)

  ;; Force fresh download
  (fetch-and-process-esi-spec :use-cache nil)

  ;; Use experimental spec
  (fetch-and-process-esi-spec :version \"_latest\")"
  (let* ((spec-url (or url
                       (cdr (assoc version *esi-spec-versions* :test #'string=))
                       *esi-spec-url*))
         ;; Try cache first
         (cached-spec (when use-cache (load-cached-spec version)))
         ;; Download if needed
         (raw-spec (or cached-spec (download-esi-spec :url spec-url)))
         (from-cache (and cached-spec t)))
    ;; Cache the fresh download
    (when (and cache-result (not from-cache) raw-spec)
      (handler-case
          (save-spec-to-cache (com.inuoe.jzon:stringify raw-spec) version)
        (error (e)
          (log-warn "Failed to cache spec: ~A" e))))
    ;; Process the raw spec into structured data
    (process-raw-spec raw-spec
                      :source-url spec-url
                      :fetched-at (get-universal-time))))

(defun process-raw-spec (raw-spec &key source-url (fetched-at (get-universal-time)))
  "Process a raw OpenAPI spec hash-table into a fully structured esi-spec.

RAW-SPEC: Hash-table from jzon representing the full OpenAPI document
SOURCE-URL: URL the spec was fetched from
FETCHED-AT: Universal time of fetch

Returns an ESI-SPEC struct with all endpoints, parameters, and schemas extracted."
  (log-info "Processing ESI spec...")
  (let* ((info (ht-get raw-spec "info"))
         (title (ht-get info "title"))
         (version (ht-get info "version"))
         (base-path (ht-get raw-spec "basePath"))
         (host (ht-get raw-spec "host"))
         (schemes (ht-get-list raw-spec "schemes"))
         ;; Parse global parameters (shared across endpoints)
         (global-params (parse-global-parameters raw-spec))
         ;; Parse security definitions
         (security-defs (ht-get raw-spec "securityDefinitions"))
         ;; Parse all endpoints
         (endpoints (process-all-endpoints raw-spec global-params))
         ;; Extract unique categories
         (categories (extract-categories endpoints)))
    (let ((spec (%make-esi-spec
                 :title title
                 :version version
                 :base-path base-path
                 :host host
                 :schemes schemes
                 :endpoints endpoints
                 :global-parameters global-params
                 :security-definitions security-defs
                 :categories categories
                 :raw-spec raw-spec
                 :fetched-at fetched-at
                 :source-url source-url)))
      ;; Validate and log summary
      (multiple-value-bind (valid-p issues) (validate-esi-spec spec)
        (if valid-p
            (log-info "ESI spec processed: ~A v~A - ~D endpoints in ~D categories"
                      title version
                      (length endpoints) (length categories))
            (progn
              (log-warn "ESI spec has ~D validation issues:" (length issues))
              (dolist (issue issues)
                (log-warn "  - ~A" issue)))))
      spec)))

;;; ---------------------------------------------------------------------------
;;; Global parameter processing
;;; ---------------------------------------------------------------------------

(defun parse-global-parameters (spec-hash)
  "Parse the top-level 'parameters' section of the OpenAPI spec.
These are shared parameter definitions referenced by $ref from endpoint parameters.

SPEC-HASH: The full OpenAPI specification hash-table

Returns a hash-table mapping parameter names to parameter-definition structs."
  (let ((params-hash (ht-get spec-hash "parameters"))
        (result (make-hash-table :test 'equal)))
    (when params-hash
      (maphash
       (lambda (name param-hash)
         (setf (gethash name result)
               (parse-parameter param-hash)))
       params-hash))
    result))

;;; ---------------------------------------------------------------------------
;;; Endpoint processing
;;; ---------------------------------------------------------------------------

(defun process-all-endpoints (spec-hash global-params)
  "Process all path entries in the OpenAPI spec into endpoint-definition structs.

SPEC-HASH: The full OpenAPI specification hash-table
GLOBAL-PARAMS: Hash-table of global parameter-definition structs

Returns a list of endpoint-definition structs, sorted by operation-id."
  (let ((paths-hash (ht-get spec-hash "paths"))
        (endpoints '()))
    (when paths-hash
      (maphash
       (lambda (path methods-hash)
         (maphash
          (lambda (method operation-hash)
            (let ((endpoint (process-single-endpoint
                             path method operation-hash
                             spec-hash global-params)))
              (when endpoint
                (push endpoint endpoints))))
          methods-hash))
       paths-hash))
    ;; Sort for deterministic output
    (sort endpoints #'string<
          :key (lambda (ep) (or (endpoint-definition-operation-id ep) "")))))

(defun process-single-endpoint (path method-string operation-hash spec-hash global-params)
  "Process a single endpoint operation into an endpoint-definition.

PATH: URL path template string (e.g., \"/characters/{character_id}/\")
METHOD-STRING: HTTP method string (\"get\", \"post\", etc.)
OPERATION-HASH: Hash-table of the operation definition
SPEC-HASH: Full spec for $ref resolution
GLOBAL-PARAMS: Global parameter definitions

Returns an ENDPOINT-DEFINITION struct, or NIL for non-operation entries."
  ;; Skip non-HTTP method entries (e.g., "parameters" at path level)
  (unless (member method-string '("get" "post" "put" "delete" "patch" "head" "options")
                  :test #'string-equal)
    (return-from process-single-endpoint nil))
  (let* ((method (intern (string-upcase method-string) :keyword))
         (operation-id (ht-get operation-hash "operationId"))
         (description (ht-get operation-hash "description"))
         (summary (extract-summary description))
         (tags (ht-get-list operation-hash "tags"))
         (deprecated-p (ht-get operation-hash "deprecated"))
         ;; Parse parameters (resolving $refs)
         (raw-params (ht-get-list operation-hash "parameters"))
         (parameters (resolve-and-parse-parameters raw-params spec-hash global-params))
         ;; Classify parameters by location
         (path-params (remove-if-not (lambda (p) (eq (parameter-definition-location p) :path))
                                     parameters))
         (query-params (remove-if-not (lambda (p) (eq (parameter-definition-location p) :query))
                                      parameters))
         (header-params (remove-if-not (lambda (p) (eq (parameter-definition-location p) :header))
                                       parameters))
         (body-param (find :body parameters :key #'parameter-definition-location))
         ;; Parse response schema
         (responses (ht-get operation-hash "responses"))
         (ok-response (ht-get responses "200"))
         (response-schema (when ok-response
                            (let ((schema-hash (ht-get ok-response "schema")))
                              (when schema-hash
                                (parse-schema schema-hash
                                              :name (format nil "~A-response" operation-id))))))
         (response-description (when ok-response
                                 (ht-get ok-response "description")))
         ;; Parse security requirements
         (security (ht-get-list operation-hash "security"))
         (requires-auth (and security (plusp (length security))))
         (required-scopes (extract-required-scopes security))
         ;; Extract metadata from description
         (cache-duration (extract-cache-duration description))
         (alternate-routes (extract-alternate-routes description))
         ;; Check for pagination
         (paginated (endpoint-paginated-p ok-response))
         ;; Determine category from path
         (category (extract-category-from-path path)))
    (make-endpoint-definition
     :operation-id operation-id
     :function-name (when operation-id (operation-id->function-name operation-id))
     :path path
     :method method
     :description description
     :summary summary
     :category category
     :parameters parameters
     :path-parameters path-params
     :query-parameters query-params
     :header-parameters header-params
     :body-parameter body-param
     :response-schema response-schema
     :response-description response-description
     :requires-auth-p requires-auth
     :required-scopes required-scopes
     :cache-duration cache-duration
     :paginated-p paginated
     :alternate-routes alternate-routes
     :deprecated-p (and deprecated-p (not (eq deprecated-p :false)) t)
     :tags tags)))

;;; ---------------------------------------------------------------------------
;;; Parameter processing
;;; ---------------------------------------------------------------------------

(defun resolve-and-parse-parameters (raw-params spec-hash global-params)
  "Resolve $ref parameters and parse all parameters for an endpoint.

RAW-PARAMS: List of parameter hash-tables (may contain $ref entries)
SPEC-HASH: Full spec for resolving references
GLOBAL-PARAMS: Pre-parsed global parameter definitions

Returns a list of parameter-definition structs.
Filters out parameters that are ESI infrastructure (datasource, token, 
If-None-Match, Accept-Language) since those are handled automatically
by the HTTP client middleware."
  (let ((parsed-params '()))
    (dolist (param-hash raw-params)
      (let* ((ref (ht-get param-hash "$ref"))
             (param (if ref
                        (resolve-parameter raw-params ref spec-hash global-params)
                        (parse-parameter param-hash))))
        (when (and param
                   (not (infrastructure-parameter-p
                         (parameter-definition-name param))))
          (push param parsed-params))))
    (nreverse parsed-params)))

(defun resolve-parameter (raw-params ref-string spec-hash global-params)
  "Resolve a parameter $ref to a parameter-definition.

RAW-PARAMS: Unused (for consistency with the calling convention)
REF-STRING: The $ref path string
SPEC-HASH: Full spec for resolution
GLOBAL-PARAMS: Pre-parsed global parameters (checked first for efficiency)

Returns a parameter-definition struct, or NIL."
  (declare (ignore raw-params))
  (multiple-value-bind (name section) (resolve-ref ref-string)
    (cond
      ;; Check pre-parsed global parameters first
      ((and name (string= section "parameters"))
       (or (gethash name global-params)
           ;; Fallback to raw resolution
           (let ((param-hash (resolve-parameter-ref ref-string spec-hash)))
             (when param-hash
               (parse-parameter param-hash)))))
      ;; Other ref types
      (t
       (log-warn "Unsupported parameter $ref: ~A" ref-string)
       nil))))

(defun parse-parameter (param-hash)
  "Parse a single parameter hash-table into a parameter-definition struct.

PARAM-HASH: Hash-table representing a single OpenAPI parameter definition

Returns a PARAMETER-DEFINITION struct."
  (let* ((name (ht-get param-hash "name"))
         (location-str (ht-get param-hash "in"))
         (location (when location-str
                     (intern (string-upcase location-str) :keyword)))
         (required (ht-get param-hash "required"))
         (description (ht-get param-hash "description"))
         (default-val (ht-get param-hash "default"))
         (enum-values (ht-get-list param-hash "enum"))
         ;; Build a schema from the parameter type info
         (schema (if (eq location :body)
                     ;; Body params have an explicit "schema" key
                     (let ((schema-hash (ht-get param-hash "schema")))
                       (when schema-hash
                         (parse-schema schema-hash :name name)))
                     ;; Non-body params define type/format directly
                     (parse-schema param-hash :name name))))
    (make-parameter-definition
     :name name
     :cl-name (when name (json-name->lisp-name name))
     :location location
     :required-p (and required (not (eq required :false)) t)
     :description description
     :schema schema
     :default-value default-val
     :enum-values enum-values)))

(defun infrastructure-parameter-p (name)
  "Return T if NAME is an infrastructure parameter handled automatically.
These parameters are managed by the HTTP client middleware and should not
appear as function parameters in generated code.

NAME: Parameter name string

Infrastructure parameters:
  - datasource: Always 'tranquility', set by client config
  - token: OAuth token, managed by auth middleware
  - If-None-Match: ETag caching, managed by cache middleware
  - Accept-Language: Set by client headers"
  (member name '("datasource" "token" "If-None-Match" "Accept-Language")
          :test #'string-equal))

;;; ---------------------------------------------------------------------------
;;; Description parsing utilities
;;; ---------------------------------------------------------------------------

(defun extract-summary (description)
  "Extract the summary (first line/paragraph) from an endpoint description.
ESI descriptions follow the pattern: summary text, then '---' separator,
then alternate routes, then caching info.

DESCRIPTION: Full description string from the spec

Returns the summary portion, or the full description if no separator found."
  (when description
    (let ((separator-pos (search "---" description)))
      (if separator-pos
          (string-trim '(#\Space #\Newline #\Return #\Tab)
                       (subseq description 0 separator-pos))
          (string-trim '(#\Space #\Newline #\Return #\Tab) description)))))

(defun extract-cache-duration (description)
  "Extract cache duration in seconds from an endpoint description.
ESI descriptions include cache info like 'This route is cached for up to 3600 seconds'.

DESCRIPTION: Full description string from the spec

Returns an integer (seconds), or NIL if no cache info found.

Example:
  (extract-cache-duration \"...This route is cached for up to 3600 seconds\")
    => 3600"
  (when description
    (multiple-value-bind (match groups)
        (cl-ppcre:scan-to-strings
         "cached for up to (\\d+) seconds" description)
      (when match
        (parse-integer (aref groups 0) :junk-allowed t)))))

(defun extract-alternate-routes (description)
  "Extract alternate route paths from an endpoint description.
ESI descriptions include lines like 'Alternate route: `/v5/characters/{character_id}/`'.

DESCRIPTION: Full description string from the spec

Returns a list of alternate route path strings.

Example:
  (extract-alternate-routes \"...Alternate route: `/v5/characters/{character_id}/`...\")
    => (\"/v5/characters/{character_id}/\")"
  (when description
    (let ((routes '()))
      (cl-ppcre:do-matches-as-strings (match "Alternate route: `([^`]+)`" description)
        (multiple-value-bind (full-match groups)
            (cl-ppcre:scan-to-strings "Alternate route: `([^`]+)`" match)
          (declare (ignore full-match))
          (when groups
            (push (aref groups 0) routes))))
      (nreverse routes))))

(defun extract-required-scopes (security-list)
  "Extract the required OAuth scope names from a security requirement list.

SECURITY-LIST: List of security requirement objects from the spec.
  Each is a hash-table mapping security scheme name to list of required scopes.

Returns a flat list of scope name strings.

Example:
  For security: [{\"evesso\": [\"esi-assets.read_assets.v1\"]}]
  Returns: (\"esi-assets.read_assets.v1\")"
  (let ((scopes '()))
    (dolist (requirement security-list)
      (when (hash-table-p requirement)
        (maphash (lambda (scheme scope-list)
                   (declare (ignore scheme))
                   (let ((scope-items (if (vectorp scope-list)
                                          (coerce scope-list 'list)
                                          scope-list)))
                     (dolist (scope scope-items)
                       (when (stringp scope)
                         (pushnew scope scopes :test #'string=)))))
                 requirement)))
    (nreverse scopes)))

(defun extract-category-from-path (path)
  "Extract the endpoint category from a URL path.
The category is the first segment of the path after the leading slash.

PATH: URL path template string

Returns the category string.

Example:
  (extract-category-from-path \"/characters/{character_id}/\") => \"characters\"
  (extract-category-from-path \"/markets/{region_id}/orders/\") => \"markets\""
  (when path
    (let* ((clean (string-left-trim "/" path))
           (slash-pos (position #\/ clean)))
      (if slash-pos
          (subseq clean 0 slash-pos)
          clean))))

(defun endpoint-paginated-p (ok-response-hash)
  "Determine whether an endpoint supports pagination by checking for X-Pages header.

OK-RESPONSE-HASH: The 200 response definition hash-table

Returns T if the endpoint has X-Pages in its response headers."
  (when ok-response-hash
    (let* ((headers (ht-get ok-response-hash "headers")))
      (and headers
           (ht-get headers "X-Pages")
           t))))

;;; ---------------------------------------------------------------------------
;;; Category extraction
;;; ---------------------------------------------------------------------------

(defun extract-categories (endpoints)
  "Extract unique categories from a list of endpoint definitions.

ENDPOINTS: List of endpoint-definition structs

Returns a sorted list of unique category strings."
  (let ((categories (make-hash-table :test 'equal)))
    (dolist (ep endpoints)
      (when-let ((cat (endpoint-definition-category ep)))
        (setf (gethash cat categories) t)))
    (sort (loop for cat being the hash-keys of categories
                collect cat)
          #'string<)))

;;; ---------------------------------------------------------------------------
;;; Spec validation
;;; ---------------------------------------------------------------------------

(defun validate-esi-spec (spec)
  "Validate a processed ESI spec for completeness and consistency.

SPEC: An esi-spec struct to validate

Returns two values:
  1. T if valid, NIL otherwise
  2. List of validation issue strings (empty if valid)"
  (let ((issues '()))
    ;; Check basic metadata
    (unless (esi-spec-title spec)
      (push "Spec has no title" issues))
    (unless (esi-spec-version spec)
      (push "Spec has no version" issues))
    (unless (esi-spec-host spec)
      (push "Spec has no host" issues))
    ;; Check endpoints exist
    (unless (esi-spec-endpoints spec)
      (push "Spec has no endpoints" issues))
    ;; Check each endpoint for basics
    (dolist (ep (esi-spec-endpoints spec))
      (unless (endpoint-definition-operation-id ep)
        (push (format nil "Endpoint ~A ~A has no operationId"
                       (endpoint-definition-method ep)
                       (endpoint-definition-path ep))
              issues))
      (unless (endpoint-definition-path ep)
        (push (format nil "Endpoint ~A has no path"
                       (endpoint-definition-operation-id ep))
              issues)))
    ;; Validate endpoints with auth have scopes
    (let ((auth-no-scopes
            (count-if (lambda (ep)
                        (and (endpoint-definition-requires-auth-p ep)
                             (null (endpoint-definition-required-scopes ep))))
                      (esi-spec-endpoints spec))))
      (when (> auth-no-scopes 0)
        (push (format nil "~D authenticated endpoints have no required scopes defined"
                       auth-no-scopes)
              issues)))
    ;; Summary statistics for info
    (let ((total (length (esi-spec-endpoints spec)))
          (with-schemas (count-if #'endpoint-definition-response-schema
                                  (esi-spec-endpoints spec)))
          (paginated (count-if #'endpoint-definition-paginated-p
                               (esi-spec-endpoints spec))))
      (log-debug "Spec stats: ~D endpoints, ~D with response schemas, ~D paginated"
                 total with-schemas paginated))
    (values (null issues) (nreverse issues))))

;;; ---------------------------------------------------------------------------
;;; Spec querying utilities
;;; ---------------------------------------------------------------------------

(defun find-endpoint-by-id (spec operation-id)
  "Find an endpoint by its operation ID.

SPEC: An esi-spec struct
OPERATION-ID: Operation ID string (e.g., \"get_characters_character_id\")

Returns the endpoint-definition, or NIL."
  (find operation-id (esi-spec-endpoints spec)
        :key #'endpoint-definition-operation-id
        :test #'string=))

(defun find-endpoints-by-category (spec category)
  "Find all endpoints in a given category.

SPEC: An esi-spec struct
CATEGORY: Category string (e.g., \"characters\", \"markets\")

Returns a list of endpoint-definition structs."
  (remove-if-not (lambda (ep)
                   (string-equal (endpoint-definition-category ep) category))
                 (esi-spec-endpoints spec)))

(defun find-endpoints-by-method (spec method)
  "Find all endpoints using a given HTTP method.

SPEC: An esi-spec struct
METHOD: HTTP method keyword (:GET, :POST, etc.)

Returns a list of endpoint-definition structs."
  (remove-if-not (lambda (ep)
                   (eq (endpoint-definition-method ep) method))
                 (esi-spec-endpoints spec)))

(defun find-authenticated-endpoints (spec)
  "Find all endpoints that require authentication.

SPEC: An esi-spec struct

Returns a list of endpoint-definition structs."
  (remove-if-not #'endpoint-definition-requires-auth-p
                 (esi-spec-endpoints spec)))

(defun find-public-endpoints (spec)
  "Find all endpoints that do NOT require authentication.

SPEC: An esi-spec struct

Returns a list of endpoint-definition structs."
  (remove-if #'endpoint-definition-requires-auth-p
             (esi-spec-endpoints spec)))

(defun find-paginated-endpoints (spec)
  "Find all endpoints that support pagination.

SPEC: An esi-spec struct

Returns a list of endpoint-definition structs."
  (remove-if-not #'endpoint-definition-paginated-p
                 (esi-spec-endpoints spec)))

;;; ---------------------------------------------------------------------------
;;; Spec summary and reporting
;;; ---------------------------------------------------------------------------

(defun spec-summary (spec &key (stream *standard-output*) verbose)
  "Print a human-readable summary of the processed ESI spec.

SPEC: An esi-spec struct
STREAM: Output stream (default: *standard-output*)
VERBOSE: If T, include per-category endpoint listing

Returns NIL (output is printed to STREAM)."
  (format stream "~&ESI Specification Summary~%")
  (format stream "~A~%" (make-string 60 :initial-element #\=))
  (format stream "Title: ~A~%" (esi-spec-title spec))
  (format stream "Version: ~A~%" (esi-spec-version spec))
  (format stream "Host: ~A~%" (esi-spec-host spec))
  (format stream "Base Path: ~A~%" (esi-spec-base-path spec))
  (format stream "~%Endpoints: ~D total~%" (length (esi-spec-endpoints spec)))
  ;; Method breakdown
  (let ((methods (make-hash-table)))
    (dolist (ep (esi-spec-endpoints spec))
      (incf (gethash (endpoint-definition-method ep) methods 0)))
    (maphash (lambda (method count)
               (format stream "  ~A: ~D~%" method count))
             methods))
  ;; Auth breakdown
  (let ((auth-count (count-if #'endpoint-definition-requires-auth-p
                              (esi-spec-endpoints spec)))
        (public-count (count-if-not #'endpoint-definition-requires-auth-p
                                    (esi-spec-endpoints spec))))
    (format stream "~%Authentication: ~D require auth, ~D public~%"
            auth-count public-count))
  ;; Pagination
  (let ((paginated (count-if #'endpoint-definition-paginated-p
                             (esi-spec-endpoints spec))))
    (format stream "Paginated: ~D endpoints~%" paginated))
  ;; Categories
  (format stream "~%Categories (~D):~%" (length (esi-spec-categories spec)))
  (dolist (cat (esi-spec-categories spec))
    (let ((count (length (find-endpoints-by-category spec cat))))
      (format stream "  ~A: ~D endpoints~%" cat count)))
  ;; Verbose per-category listing
  (when verbose
    (dolist (cat (esi-spec-categories spec))
      (format stream "~%~A (~A):~%" cat
              (make-string (length cat) :initial-element #\-))
      (dolist (ep (find-endpoints-by-category spec cat))
        (format stream "  ~A ~A ~A~@[ (auth: ~{~A~^, ~})~]~%"
                (endpoint-definition-method ep)
                (endpoint-definition-path ep)
                (endpoint-definition-operation-id ep)
                (endpoint-definition-required-scopes ep)))))
  (values))

;;; ---------------------------------------------------------------------------
;;; Common Lisp type definition generation
;;; ---------------------------------------------------------------------------

(defun generate-cl-type-definitions (spec)
  "Generate Common Lisp type definition forms from the spec's response schemas.

SPEC: An esi-spec struct

Returns a list of (DEFTYPE name () type-body) forms that can be evaluated
or written to a file.

Each endpoint's 200 response schema is converted into a type definition,
with the name derived from the operation-id."
  (let ((type-defs '()))
    (dolist (ep (esi-spec-endpoints spec))
      (when-let ((schema (endpoint-definition-response-schema ep)))
        (let* ((op-id (endpoint-definition-operation-id ep))
               (type-name (intern (string-upcase
                                   (operation-id->function-name op-id))
                                  :eve-gate.api))
               (cl-type (schema-definition-cl-type schema))
               (description (or (schema-definition-description schema)
                                (endpoint-definition-summary ep))))
          (push `(deftype ,type-name ()
                   ,description
                   ',cl-type)
                type-defs))))
    (nreverse type-defs)))

(defun generate-response-type-map (spec)
  "Generate a mapping from operation-ids to their response type information.

SPEC: An esi-spec struct

Returns a hash-table mapping operation-id strings to schema-definition structs.
This is used by the code generator to know what type each endpoint returns."
  (let ((type-map (make-hash-table :test 'equal)))
    (dolist (ep (esi-spec-endpoints spec))
      (when (endpoint-definition-response-schema ep)
        (setf (gethash (endpoint-definition-operation-id ep) type-map)
              (endpoint-definition-response-schema ep))))
    type-map))

;;; ---------------------------------------------------------------------------
;;; Versioning support
;;; ---------------------------------------------------------------------------

(defun compare-spec-versions (spec-a spec-b)
  "Compare two ESI specs and report differences.

SPEC-A: First esi-spec struct  
SPEC-B: Second esi-spec struct

Returns a plist with:
  :ADDED-ENDPOINTS    - operation-ids in B but not A
  :REMOVED-ENDPOINTS  - operation-ids in A but not B
  :COMMON-ENDPOINTS   - operation-ids in both
  :VERSION-A          - version string of A
  :VERSION-B          - version string of B"
  (let* ((ids-a (mapcar #'endpoint-definition-operation-id
                         (esi-spec-endpoints spec-a)))
         (ids-b (mapcar #'endpoint-definition-operation-id
                         (esi-spec-endpoints spec-b)))
         (added (set-difference ids-b ids-a :test #'string=))
         (removed (set-difference ids-a ids-b :test #'string=))
         (common (intersection ids-a ids-b :test #'string=)))
    (list :added-endpoints (sort (copy-list added) #'string<)
          :removed-endpoints (sort (copy-list removed) #'string<)
          :common-endpoints (sort (copy-list common) #'string<)
          :version-a (esi-spec-version spec-a)
          :version-b (esi-spec-version spec-b))))

(defun spec-version-summary (diff &key (stream *standard-output*))
  "Print a human-readable summary of spec version differences.

DIFF: Plist from COMPARE-SPEC-VERSIONS
STREAM: Output stream"
  (format stream "~&Spec Version Comparison~%")
  (format stream "  Version A: ~A~%" (getf diff :version-a))
  (format stream "  Version B: ~A~%" (getf diff :version-b))
  (format stream "  Common endpoints: ~D~%" (length (getf diff :common-endpoints)))
  (let ((added (getf diff :added-endpoints))
        (removed (getf diff :removed-endpoints)))
    (when added
      (format stream "  Added (~D):~%" (length added))
      (dolist (id added)
        (format stream "    + ~A~%" id)))
    (when removed
      (format stream "  Removed (~D):~%" (length removed))
      (dolist (id removed)
        (format stream "    - ~A~%" id))))
  (values))
