;;;; response-types.lisp - Common ESI response structure types for eve-gate
;;;;
;;;; Defines structured types for ESI API responses, providing a uniform
;;;; interface for accessing response data, metadata, and pagination info.
;;;;
;;;; ESI responses include several layers of information:
;;;;   - The response body (JSON data as hash-tables, vectors, or scalars)
;;;;   - HTTP metadata (status, headers, ETag, cache expiry)
;;;;   - Pagination metadata (page count, total items for paginated endpoints)
;;;;   - Rate limit information (remaining requests, window reset)
;;;;
;;;; These types complement the esi-response struct in the core HTTP client
;;;; by providing higher-level, typed access to response data. The core
;;;; esi-response deals with raw HTTP responses; these response types
;;;; deal with parsed, validated ESI data.
;;;;
;;;; Design: Structs with typed slots for compile-time safety and
;;;; documentation. Constructor functions handle parsing and extraction
;;;; from raw esi-response objects.

(in-package #:eve-gate.types)

;;; ---------------------------------------------------------------------------
;;; Pagination metadata
;;; ---------------------------------------------------------------------------

(defstruct (pagination-info (:constructor %make-pagination-info))
  "Metadata for paginated ESI endpoint responses.

ESI uses header-based pagination:
  X-Pages: Total number of pages available
  (Page size is fixed per endpoint, typically 1000-5000 items)

Slots:
  CURRENT-PAGE: The page number that was requested (1-indexed)
  TOTAL-PAGES: Total number of pages available (from X-Pages header)
  HAS-MORE-P: Whether there are more pages after the current one
  PAGE-SIZE: Estimated items per page (not always provided by ESI)"
  (current-page 1 :type (integer 1))
  (total-pages 1 :type (integer 1))
  (has-more-p nil :type boolean)
  (page-size nil :type (or null (integer 1))))

(defun make-pagination-info (&key (current-page 1) (total-pages 1) (page-size nil))
  "Create pagination info from page parameters.

CURRENT-PAGE: The requested page number (default: 1)
TOTAL-PAGES: Total pages from X-Pages header (default: 1)
PAGE-SIZE: Items per page, if known

Returns a pagination-info struct."
  (%make-pagination-info
   :current-page current-page
   :total-pages total-pages
   :has-more-p (< current-page total-pages)
   :page-size page-size))

(defun extract-pagination-from-headers (headers &key (current-page 1))
  "Extract pagination info from ESI response headers.

HEADERS: Response headers (hash-table or alist)
CURRENT-PAGE: The page number that was requested

Returns a pagination-info struct, or NIL if no pagination headers found."
  (let ((x-pages (extract-header-value headers "x-pages")))
    (when x-pages
      (let ((total-pages (parse-integer x-pages :junk-allowed t)))
        (when (and total-pages (plusp total-pages))
          (make-pagination-info
           :current-page current-page
           :total-pages total-pages))))))

;;; ---------------------------------------------------------------------------
;;; Rate limit metadata
;;; ---------------------------------------------------------------------------

(defstruct (rate-limit-info (:constructor %make-rate-limit-info))
  "Rate limit information from ESI response headers.

ESI tracks two rate limit mechanisms:
  1. Per-IP request limits (X-ESI-Error-Limit-Remain / X-ESI-Error-Limit-Reset)
  2. Error rate limiting (420 status with Retry-After)

Slots:
  ERROR-LIMIT-REMAIN: Remaining error budget (from X-ESI-Error-Limit-Remain)
  ERROR-LIMIT-RESET: Seconds until error window resets (from X-ESI-Error-Limit-Reset)
  RETRY-AFTER: Seconds to wait before retrying (from Retry-After, when rate limited)
  RATE-LIMITED-P: Whether this response indicates active rate limiting"
  (error-limit-remain nil :type (or null integer))
  (error-limit-reset nil :type (or null integer))
  (retry-after nil :type (or null integer))
  (rate-limited-p nil :type boolean))

(defun make-rate-limit-info (&key error-limit-remain error-limit-reset
                                   retry-after rate-limited-p)
  "Create rate limit info from parsed header values."
  (%make-rate-limit-info
   :error-limit-remain error-limit-remain
   :error-limit-reset error-limit-reset
   :retry-after retry-after
   :rate-limited-p (or rate-limited-p (not (null retry-after)))))

(defun extract-rate-limit-from-headers (headers)
  "Extract rate limit information from ESI response headers.

HEADERS: Response headers (hash-table or alist)

Returns a rate-limit-info struct with whatever information is available."
  (let ((remain (extract-header-value headers "x-esi-error-limit-remain"))
        (reset (extract-header-value headers "x-esi-error-limit-reset"))
        (retry (extract-header-value headers "retry-after")))
    (make-rate-limit-info
     :error-limit-remain (when remain (parse-integer remain :junk-allowed t))
     :error-limit-reset (when reset (parse-integer reset :junk-allowed t))
     :retry-after (when retry (parse-integer retry :junk-allowed t)))))

;;; ---------------------------------------------------------------------------
;;; Cache metadata
;;; ---------------------------------------------------------------------------

(defstruct (cache-info (:constructor %make-cache-info))
  "Cache-related metadata from ESI response headers.

Slots:
  ETAG: The ETag value for conditional requests (If-None-Match)
  EXPIRES: Expiration timestamp as a local-time:timestamp
  LAST-MODIFIED: Last modification timestamp
  CACHE-CONTROL: Raw Cache-Control header value
  CACHED-P: Whether this response was served from local cache"
  (etag nil :type (or null string))
  (expires nil)  ; local-time:timestamp or nil
  (last-modified nil)  ; local-time:timestamp or nil
  (cache-control nil :type (or null string))
  (cached-p nil :type boolean))

(defun make-cache-info (&key etag expires last-modified cache-control cached-p)
  "Create cache info from parsed values."
  (%make-cache-info
   :etag etag
   :expires expires
   :last-modified last-modified
   :cache-control cache-control
   :cached-p cached-p))

(defun extract-cache-from-headers (headers)
  "Extract cache metadata from ESI response headers.

HEADERS: Response headers (hash-table or alist)

Returns a cache-info struct."
  (let ((etag (extract-header-value headers "etag"))
        (expires (extract-header-value headers "expires"))
        (last-mod (extract-header-value headers "last-modified"))
        (cache-ctrl (extract-header-value headers "cache-control")))
    (make-cache-info
     :etag etag
     :expires (when expires (parse-http-date expires))
     :last-modified (when last-mod (parse-http-date last-mod))
     :cache-control cache-ctrl)))

;;; ---------------------------------------------------------------------------
;;; Typed API response wrapper
;;; ---------------------------------------------------------------------------

(defstruct (api-response (:constructor %make-api-response))
  "Complete typed response from an ESI API call.

Wraps the response data with all associated metadata, providing a single
object that captures everything about an API call result.

Slots:
  DATA: The parsed response body (hash-table, list, number, string, or NIL)
  STATUS: HTTP status code (integer)
  HEADERS: Response headers (hash-table)
  PAGINATION: Pagination metadata (pagination-info or NIL)
  RATE-LIMIT: Rate limit metadata (rate-limit-info)
  CACHE: Cache metadata (cache-info)
  ENDPOINT: The endpoint path that was called
  TIMESTAMP: When this response was received (universal-time)"
  (data nil)
  (status 200 :type integer)
  (headers nil :type (or null hash-table))
  (pagination nil :type (or null pagination-info))
  (rate-limit nil :type (or null rate-limit-info))
  (cache nil :type (or null cache-info))
  (endpoint nil :type (or null string))
  (timestamp (get-universal-time) :type integer))

(defun make-api-response (&key data status headers pagination rate-limit
                                cache endpoint)
  "Create a typed API response from components.

DATA: Parsed response body
STATUS: HTTP status code
HEADERS: Response headers hash-table
PAGINATION: Pagination metadata (or extracted from headers)
RATE-LIMIT: Rate limit info (or extracted from headers)
CACHE: Cache info (or extracted from headers)
ENDPOINT: The endpoint that was called

Returns an api-response struct."
  (%make-api-response
   :data data
   :status (or status 200)
   :headers headers
   :pagination (or pagination
                   (when headers
                     (extract-pagination-from-headers headers)))
   :rate-limit (or rate-limit
                   (when headers
                     (extract-rate-limit-from-headers headers)))
   :cache (or cache
              (when headers
                (extract-cache-from-headers headers)))
   :endpoint endpoint))

;;; ---------------------------------------------------------------------------
;;; ESI error response structure
;;; ---------------------------------------------------------------------------

(defstruct (esi-error-response (:constructor %make-esi-error-response))
  "Parsed ESI error response body.

When ESI returns a 4xx or 5xx status, the body contains JSON with
a standard error structure:
  {\"error\": \"Error description message\"}
or sometimes:
  {\"error\": \"message\", \"sso_status\": 403, \"timeout\": 5}

Slots:
  ERROR-MESSAGE: The error description string from the \"error\" field
  SSO-STATUS: SSO-specific status code, if present
  TIMEOUT: Timeout value, if present (for rate limiting)"
  (error-message "" :type string)
  (sso-status nil :type (or null integer))
  (timeout nil :type (or null integer)))

(defun make-esi-error-response (&key error-message sso-status timeout)
  "Create an ESI error response from components."
  (%make-esi-error-response
   :error-message (or error-message "Unknown error")
   :sso-status sso-status
   :timeout timeout))

(defun parse-esi-error-body (body)
  "Parse an ESI error response body into an esi-error-response struct.

BODY: The response body - either a string (JSON), hash-table (already parsed),
      or NIL.

Returns an esi-error-response struct, or NIL if the body cannot be parsed."
  (cond
    ((hash-table-p body)
     (make-esi-error-response
      :error-message (or (gethash "error" body) "Unknown error")
      :sso-status (gethash "sso_status" body)
      :timeout (gethash "timeout" body)))
    ((stringp body)
     (handler-case
         (let ((parsed (com.inuoe.jzon:parse body)))
           (when (hash-table-p parsed)
             (parse-esi-error-body parsed)))
       (error ()
         (make-esi-error-response :error-message body))))
    (t nil)))

;;; ---------------------------------------------------------------------------
;;; Response accessor utilities
;;; ---------------------------------------------------------------------------

(defun api-response-etag (response)
  "Extract the ETag from an api-response.

RESPONSE: An api-response struct

Returns the ETag string, or NIL."
  (when (api-response-cache response)
    (cache-info-etag (api-response-cache response))))

(defun api-response-expires (response)
  "Extract the expiry timestamp from an api-response.

RESPONSE: An api-response struct

Returns a local-time:timestamp, or NIL."
  (when (api-response-cache response)
    (cache-info-expires (api-response-cache response))))

(defun api-response-paginated-p (response)
  "Return T if RESPONSE contains pagination metadata indicating multiple pages."
  (when-let ((pag (api-response-pagination response)))
    (> (pagination-info-total-pages pag) 1)))

(defun api-response-has-more-pages-p (response)
  "Return T if there are more pages available after this response."
  (when-let ((pag (api-response-pagination response)))
    (pagination-info-has-more-p pag)))

(defun api-response-total-pages (response)
  "Return the total number of pages for this endpoint, or 1."
  (if-let ((pag (api-response-pagination response)))
    (pagination-info-total-pages pag)
    1))

(defun api-response-rate-limited-p (response)
  "Return T if this response indicates active rate limiting."
  (when-let ((rl (api-response-rate-limit response)))
    (rate-limit-info-rate-limited-p rl)))

(defun api-response-error-budget-remaining (response)
  "Return the number of errors remaining in the current ESI error window.
Returns NIL if the information is not available."
  (when-let ((rl (api-response-rate-limit response)))
    (rate-limit-info-error-limit-remain rl)))

(defun api-response-success-p (response)
  "Return T if the response indicates a successful API call (2xx status)."
  (<= 200 (api-response-status response) 299))

;;; ---------------------------------------------------------------------------
;;; Header extraction utility
;;; ---------------------------------------------------------------------------

(defun extract-header-value (headers name)
  "Extract a header value from HEADERS by NAME (case-insensitive).

HEADERS: Hash-table or alist of response headers
NAME: Header name string (case-insensitive lookup)

Returns the header value string, or NIL if not found."
  (cond
    ((hash-table-p headers)
     ;; Hash-table headers (from dexador)
     (or (gethash name headers)
         (gethash (string-downcase name) headers)
         (gethash (string-upcase name) headers)
         ;; Scan for case-insensitive match
         (block found
           (maphash (lambda (k v)
                      (when (string-equal k name)
                        (return-from found v)))
                    headers)
           nil)))
    ((listp headers)
     ;; Alist headers
     (cdr (assoc name headers :test #'string-equal)))
    (t nil)))

;;; ---------------------------------------------------------------------------
;;; HTTP date parsing utility
;;; ---------------------------------------------------------------------------

(defun parse-http-date (date-string)
  "Parse an HTTP date string into a local-time:timestamp.

Handles RFC 2616 date formats:
  - \"Sun, 06 Nov 1994 08:49:37 GMT\" (RFC 1123)
  - \"Sunday, 06-Nov-94 08:49:37 GMT\" (RFC 1036)
  - \"Sun Nov  6 08:49:37 1994\" (asctime)

DATE-STRING: HTTP date string

Returns a local-time:timestamp, or NIL on parse failure."
  (when (and (stringp date-string) (plusp (length date-string)))
    (handler-case
        (local-time:parse-timestring date-string :fail-on-error nil)
      (error ()
        ;; If local-time can't parse it directly, try our ESI parser
        ;; which handles ISO 8601 format
        (handler-case
            (let ((ts (parse-esi-timestamp date-string)))
              ts)
          (error () nil))))))
