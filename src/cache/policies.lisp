;;;; policies.lisp - Cache policies and TTL management for ESI endpoints
;;;;
;;;; Defines cache policies that govern how ESI responses are cached, including:
;;;;   - Per-endpoint cache duration configuration
;;;;   - ESI Cache-Control header interpretation
;;;;   - TTL computation from ESI headers and endpoint metadata
;;;;   - Invalidation strategies (time-based, manual, dependency-based)
;;;;   - Cache key generation with parameter normalization
;;;;
;;;; ESI endpoints have widely varying cache durations:
;;;;   - Server status: 30 seconds
;;;;   - Market orders: 300 seconds (5 minutes)
;;;;   - Character public info: 86400 seconds (24 hours)
;;;;   - Universe static data: 86400+ seconds
;;;;
;;;; This module ensures each endpoint gets the appropriate caching behavior,
;;;; with sensible defaults for endpoints without explicit configuration.
;;;;
;;;; Design: Pure functions for policy computation. Configuration is stored
;;;; in hash-tables that can be updated at runtime via the REPL.

(in-package #:eve-gate.cache)

;;; ---------------------------------------------------------------------------
;;; Cache policy configuration
;;; ---------------------------------------------------------------------------

(defstruct (cache-policy (:constructor %make-cache-policy))
  "Cache policy for an ESI endpoint or endpoint group.

Slots:
  NAME: Descriptive name for this policy
  TTL: Default time-to-live in seconds (overridden by ESI headers if present)
  USE-ETAG-P: Whether to use ETag-based conditional requests
  CACHE-IN-MEMORY-P: Whether to cache in L1 memory
  CACHE-IN-DB-P: Whether to cache in L2 persistent storage
  PRIORITY: Eviction priority (higher = keep longer). Range 1-10.
  INVALIDATE-ON-WRITE-P: Whether writes to related endpoints invalidate this cache
  STALE-WHILE-REVALIDATE: Seconds to serve stale data while fetching fresh data"
  (name "default" :type string)
  (ttl 300 :type (integer 0))
  (use-etag-p t :type boolean)
  (cache-in-memory-p t :type boolean)
  (cache-in-db-p nil :type boolean)
  (priority 5 :type (integer 1 10))
  (invalidate-on-write-p t :type boolean)
  (stale-while-revalidate 0 :type (integer 0)))

(defun make-cache-policy (&key (name "default")
                                (ttl 300)
                                (use-etag t)
                                (cache-in-memory t)
                                (cache-in-db nil)
                                (priority 5)
                                (invalidate-on-write t)
                                (stale-while-revalidate 0))
  "Create a cache policy.

NAME: Descriptive name
TTL: Default time-to-live in seconds (default: 300)
USE-ETAG: Use ETag conditional requests (default: T)
CACHE-IN-MEMORY: Store in L1 memory cache (default: T)
CACHE-IN-DB: Store in L2 persistent cache (default: NIL)
PRIORITY: Eviction priority 1-10 (default: 5)
INVALIDATE-ON-WRITE: Invalidate on related writes (default: T)
STALE-WHILE-REVALIDATE: Seconds to serve stale data (default: 0)

Returns a CACHE-POLICY struct."
  (%make-cache-policy
   :name name
   :ttl ttl
   :use-etag-p use-etag
   :cache-in-memory-p cache-in-memory
   :cache-in-db-p cache-in-db
   :priority (max 1 (min 10 priority))
   :invalidate-on-write-p invalidate-on-write
   :stale-while-revalidate stale-while-revalidate))

;;; ---------------------------------------------------------------------------
;;; Pre-defined ESI cache policies
;;; ---------------------------------------------------------------------------

(defparameter *policy-volatile*
  (make-cache-policy :name "volatile"
                     :ttl 30
                     :cache-in-memory t
                     :cache-in-db nil
                     :priority 2
                     :stale-while-revalidate 10)
  "Policy for frequently-changing data (e.g., server status, character location).")

(defparameter *policy-short*
  (make-cache-policy :name "short"
                     :ttl 300
                     :cache-in-memory t
                     :cache-in-db nil
                     :priority 4)
  "Policy for moderately-changing data (e.g., market orders, wallet).")

(defparameter *policy-standard*
  (make-cache-policy :name "standard"
                     :ttl 3600
                     :cache-in-memory t
                     :cache-in-db t
                     :priority 5)
  "Policy for slowly-changing data (e.g., character info, corporation info).")

(defparameter *policy-long*
  (make-cache-policy :name "long"
                     :ttl 86400
                     :cache-in-memory t
                     :cache-in-db t
                     :priority 8)
  "Policy for rarely-changing data (e.g., universe data, type info).")

(defparameter *policy-static*
  (make-cache-policy :name "static"
                     :ttl (* 7 86400)
                     :cache-in-memory t
                     :cache-in-db t
                     :priority 10
                     :invalidate-on-write nil)
  "Policy for effectively static data (e.g., dogma attributes, bloodlines).")

(defparameter *policy-no-cache*
  (make-cache-policy :name "no-cache"
                     :ttl 0
                     :use-etag nil
                     :cache-in-memory nil
                     :cache-in-db nil
                     :priority 1)
  "Policy that disables all caching (for write endpoints, UI actions).")

;;; ---------------------------------------------------------------------------
;;; Per-category default policies
;;; ---------------------------------------------------------------------------

(defparameter *category-policy-map*
  (let ((ht (make-hash-table :test 'equal)))
    ;; Map ESI categories to their default cache policies
    (setf (gethash "alliances" ht) *policy-standard*)
    (setf (gethash "characters" ht) *policy-short*)
    (setf (gethash "contracts" ht) *policy-short*)
    (setf (gethash "corporation" ht) *policy-short*)
    (setf (gethash "corporations" ht) *policy-short*)
    (setf (gethash "dogma" ht) *policy-static*)
    (setf (gethash "fleets" ht) *policy-volatile*)
    (setf (gethash "fw" ht) *policy-standard*)
    (setf (gethash "incursions" ht) *policy-short*)
    (setf (gethash "industry" ht) *policy-standard*)
    (setf (gethash "insurance" ht) *policy-long*)
    (setf (gethash "killmails" ht) *policy-standard*)
    (setf (gethash "loyalty" ht) *policy-standard*)
    (setf (gethash "markets" ht) *policy-short*)
    (setf (gethash "route" ht) *policy-long*)
    (setf (gethash "sovereignty" ht) *policy-short*)
    (setf (gethash "status" ht) *policy-volatile*)
    (setf (gethash "ui" ht) *policy-no-cache*)
    (setf (gethash "universe" ht) *policy-long*)
    (setf (gethash "wars" ht) *policy-standard*)
    ht)
  "Default cache policies for ESI endpoint categories.
These can be overridden per-endpoint via *endpoint-policy-overrides*.")

;;; ---------------------------------------------------------------------------
;;; Per-endpoint policy overrides
;;; ---------------------------------------------------------------------------

(defparameter *endpoint-policy-overrides*
  (let ((ht (make-hash-table :test 'equal)))
    ;; Override specific endpoints that differ from their category default.
    ;; Key is the operation_id string.

    ;; Very volatile character endpoints
    (setf (gethash "get_characters_character_id_location" ht) *policy-volatile*)
    (setf (gethash "get_characters_character_id_online" ht) *policy-volatile*)
    (setf (gethash "get_characters_character_id_ship" ht) *policy-volatile*)

    ;; Character public info is stable
    (setf (gethash "get_characters_character_id" ht) *policy-standard*)
    (setf (gethash "get_characters_character_id_portrait" ht) *policy-long*)
    (setf (gethash "get_characters_character_id_corporationhistory" ht) *policy-standard*)

    ;; Corporation public info is stable
    (setf (gethash "get_corporations_corporation_id" ht) *policy-standard*)
    (setf (gethash "get_corporations_corporation_id_icons" ht) *policy-long*)

    ;; Alliance info is stable
    (setf (gethash "get_alliances_alliance_id" ht) *policy-long*)

    ;; Static universe data
    (setf (gethash "get_universe_ancestries" ht) *policy-static*)
    (setf (gethash "get_universe_bloodlines" ht) *policy-static*)
    (setf (gethash "get_universe_categories" ht) *policy-static*)
    (setf (gethash "get_universe_factions" ht) *policy-static*)
    (setf (gethash "get_universe_graphics" ht) *policy-static*)
    (setf (gethash "get_universe_races" ht) *policy-static*)

    ;; Market prices change frequently
    (setf (gethash "get_markets_prices" ht) *policy-short*)
    (setf (gethash "get_markets_region_id_orders" ht) *policy-short*)
    (setf (gethash "get_markets_region_id_history" ht) *policy-standard*)

    ;; Status endpoint is very volatile
    (setf (gethash "get_status" ht) *policy-volatile*)

    ;; Write endpoints should not be cached
    (setf (gethash "post_characters_affiliation" ht) *policy-no-cache*)
    (setf (gethash "post_universe_ids" ht) *policy-no-cache*)
    (setf (gethash "post_universe_names" ht) *policy-no-cache*)

    ;; UI endpoints are fire-and-forget
    (setf (gethash "post_ui_autopilot_waypoint" ht) *policy-no-cache*)
    (setf (gethash "post_ui_openwindow_contract" ht) *policy-no-cache*)
    (setf (gethash "post_ui_openwindow_information" ht) *policy-no-cache*)
    (setf (gethash "post_ui_openwindow_marketdetails" ht) *policy-no-cache*)
    (setf (gethash "post_ui_openwindow_newmail" ht) *policy-no-cache*)

    ht)
  "Per-endpoint cache policy overrides.
Takes precedence over category defaults.
Key is the operation_id string (e.g., \"get_characters_character_id\").")

;;; ---------------------------------------------------------------------------
;;; Policy lookup
;;; ---------------------------------------------------------------------------

(defun get-cache-policy (operation-id &optional category)
  "Look up the cache policy for an ESI endpoint.

Checks in order:
  1. Per-endpoint override (*endpoint-policy-overrides*)
  2. Category default (*category-policy-map*)
  3. Global default (*policy-standard*)

OPERATION-ID: String operation ID (e.g., \"get_characters_character_id\")
CATEGORY: Optional category string (e.g., \"characters\")

Returns a CACHE-POLICY struct."
  (or
   ;; 1. Per-endpoint override
   (gethash operation-id *endpoint-policy-overrides*)
   ;; 2. Category default
   (when category
     (gethash category *category-policy-map*))
   ;; 3. Global default
   *policy-standard*))

(defun set-endpoint-policy (operation-id policy)
  "Set a custom cache policy for a specific endpoint.

OPERATION-ID: String operation ID
POLICY: A cache-policy struct

Returns the POLICY."
  (setf (gethash operation-id *endpoint-policy-overrides*) policy))

(defun set-category-policy (category policy)
  "Set a default cache policy for an entire endpoint category.

CATEGORY: Category string (e.g., \"characters\")
POLICY: A cache-policy struct

Returns the POLICY."
  (setf (gethash category *category-policy-map*) policy))

(defun cacheable-request-p (method operation-id)
  "Return T if this request should be cached.

Only GET requests are cacheable. POST/PUT/DELETE are never cached.
Additionally, the endpoint's policy must not be *policy-no-cache*.

METHOD: HTTP method keyword (:get, :post, etc.)
OPERATION-ID: String operation ID

Returns T if the request is cacheable."
  (and (eq method :get)
       (let ((policy (get-cache-policy operation-id)))
         (not (string= (cache-policy-name policy) "no-cache")))))

;;; ---------------------------------------------------------------------------
;;; TTL computation from ESI headers
;;; ---------------------------------------------------------------------------

(defun compute-ttl-from-headers (headers &optional default-ttl)
  "Compute the cache TTL from ESI response headers.

ESI provides caching hints via:
  - Cache-Control: max-age=N (primary source)
  - Expires: <date> (fallback)

If neither is available, falls back to DEFAULT-TTL.

HEADERS: Response headers (hash-table or NIL)
DEFAULT-TTL: Fallback TTL in seconds (default: 300)

Returns TTL in seconds (integer, always >= 0)."
  (let ((ttl (or (parse-cache-control-max-age headers)
                 (compute-ttl-from-expires headers)
                 default-ttl
                 300)))
    (max 0 ttl)))

(defun parse-cache-control-max-age (headers)
  "Extract max-age value from a Cache-Control header.

HEADERS: Response headers hash-table

Returns the max-age value in seconds, or NIL if not found."
  (when (hash-table-p headers)
    (let ((cc (or (gethash "cache-control" headers)
                  (gethash "Cache-Control" headers))))
      (when cc
        (let ((pos (search "max-age=" cc :test #'char-equal)))
          (when pos
            (let* ((start (+ pos 8))
                   (end (or (position-if-not #'digit-char-p cc :start start)
                            (length cc))))
              (when (> end start)
                (parse-integer (subseq cc start end) :junk-allowed t)))))))))

(defun compute-ttl-from-expires (headers)
  "Compute TTL from an Expires header.

HEADERS: Response headers hash-table

Returns TTL in seconds from now, or NIL if header not found/parseable."
  (when (hash-table-p headers)
    (let ((expires (or (gethash "expires" headers)
                       (gethash "Expires" headers))))
      (when expires
        (handler-case
            (let* ((now (get-universal-time))
                   ;; Try ISO 8601 format first (ESI sometimes uses this)
                   (ts (local-time:parse-timestring expires :fail-on-error nil))
                   (expire-ut (when ts
                                (local-time:timestamp-to-universal ts))))
              (when expire-ut
                (max 0 (- expire-ut now))))
          (error () nil))))))

;;; ---------------------------------------------------------------------------
;;; Cache key generation
;;; ---------------------------------------------------------------------------

(defun make-cache-key (endpoint &key params auth-context datasource)
  "Generate a deterministic cache key for an ESI request.

The key uniquely identifies a specific ESI response by combining:
  - The endpoint path (with path parameters substituted)
  - Query parameters (sorted for determinism)
  - Authentication context (character/corporation ID for scoped data)
  - Datasource (tranquility/singularity)

ENDPOINT: The ESI endpoint path string
PARAMS: Alist of query parameters
AUTH-CONTEXT: Authentication context string (e.g., character ID)
DATASOURCE: Datasource string (default: \"tranquility\")

Returns a deterministic cache key string.

Uses FAST-CACHE-KEY from the performance module for optimized string
construction, avoiding FORMAT overhead in this hot path.

Example:
  (make-cache-key \"/v5/characters/95465499/\"
                  :params '((\"datasource\" . \"tranquility\"))
                  :auth-context \"95465499\")
  => \"esi:/v5/characters/95465499/?datasource=tranquility|auth:95465499|ds:tranquility\""
  (fast-cache-key endpoint params auth-context datasource))

(defun extract-auth-context-from-params (params)
  "Extract authentication context from request parameters.

For per-character or per-corporation caching, we need to partition
the cache by the entity making the request.

PARAMS: Alist of request parameters

Returns an auth context string, or NIL for public endpoints."
  (or (cdr (assoc "character_id" params :test #'string=))
      (cdr (assoc "corporation_id" params :test #'string=))
      (cdr (assoc "alliance_id" params :test #'string=))))

;;; ---------------------------------------------------------------------------
;;; Write invalidation
;;; ---------------------------------------------------------------------------

(defparameter *write-invalidation-rules*
  (let ((ht (make-hash-table :test 'equal)))
    ;; When a POST/PUT/DELETE is made to these endpoints, invalidate
    ;; the specified patterns from cache.
    ;; Format: write-operation-id -> list of read-operation-ids to invalidate

    ;; Contact writes invalidate contact reads
    (setf (gethash "post_characters_character_id_contacts" ht)
          '("get_characters_character_id_contacts"
            "get_characters_character_id_contacts_labels"))
    (setf (gethash "put_characters_character_id_contacts" ht)
          '("get_characters_character_id_contacts"))
    (setf (gethash "delete_characters_character_id_contacts" ht)
          '("get_characters_character_id_contacts"))

    ;; Fitting writes invalidate fitting reads
    (setf (gethash "post_characters_character_id_fittings" ht)
          '("get_characters_character_id_fittings"))
    (setf (gethash "delete_characters_character_id_fittings_fitting_id" ht)
          '("get_characters_character_id_fittings"))

    ;; Mail writes invalidate mail reads
    (setf (gethash "post_characters_character_id_mail" ht)
          '("get_characters_character_id_mail"
            "get_characters_character_id_mail_labels"))
    (setf (gethash "put_characters_character_id_mail_mail_id" ht)
          '("get_characters_character_id_mail"
            "get_characters_character_id_mail_mail_id"))
    (setf (gethash "delete_characters_character_id_mail_mail_id" ht)
          '("get_characters_character_id_mail"))
    (setf (gethash "delete_characters_character_id_mail_labels_label_id" ht)
          '("get_characters_character_id_mail_labels"))
    (setf (gethash "post_characters_character_id_mail_labels" ht)
          '("get_characters_character_id_mail_labels"))

    ;; Calendar event response invalidates event data
    (setf (gethash "put_characters_character_id_calendar_event_id" ht)
          '("get_characters_character_id_calendar"
            "get_characters_character_id_calendar_event_id"
            "get_characters_character_id_calendar_event_id_attendees"))

    ;; Fleet writes invalidate fleet reads
    (setf (gethash "put_fleets_fleet_id" ht)
          '("get_fleets_fleet_id"))
    (setf (gethash "post_fleets_fleet_id_members" ht)
          '("get_fleets_fleet_id_members"))
    (setf (gethash "delete_fleets_fleet_id_members_member_id" ht)
          '("get_fleets_fleet_id_members"))
    (setf (gethash "put_fleets_fleet_id_members_member_id" ht)
          '("get_fleets_fleet_id_members"))
    (setf (gethash "post_fleets_fleet_id_wings" ht)
          '("get_fleets_fleet_id_wings"))
    (setf (gethash "delete_fleets_fleet_id_wings_wing_id" ht)
          '("get_fleets_fleet_id_wings"))
    (setf (gethash "put_fleets_fleet_id_wings_wing_id" ht)
          '("get_fleets_fleet_id_wings"))
    (setf (gethash "post_fleets_fleet_id_wings_wing_id_squads" ht)
          '("get_fleets_fleet_id_wings"))
    (setf (gethash "delete_fleets_fleet_id_squads_squad_id" ht)
          '("get_fleets_fleet_id_wings"))
    (setf (gethash "put_fleets_fleet_id_squads_squad_id" ht)
          '("get_fleets_fleet_id_wings"))

    ht)
  "Rules for invalidating cached GET data when a write operation occurs.
Maps write operation IDs to lists of read operation IDs that should
be invalidated from cache.")

(defun get-invalidation-targets (write-operation-id)
  "Return the list of operation IDs whose cached data should be
invalidated when WRITE-OPERATION-ID is executed.

WRITE-OPERATION-ID: String operation ID of a POST/PUT/DELETE operation

Returns a list of operation ID strings, or NIL."
  (gethash write-operation-id *write-invalidation-rules*))

;;; ---------------------------------------------------------------------------
;;; Policy introspection for REPL
;;; ---------------------------------------------------------------------------

(defun list-all-policies ()
  "Return a list of all pre-defined cache policies.

Returns a list of (name policy) pairs."
  (list (list "volatile" *policy-volatile*)
        (list "short" *policy-short*)
        (list "standard" *policy-standard*)
        (list "long" *policy-long*)
        (list "static" *policy-static*)
        (list "no-cache" *policy-no-cache*)))

(defun policy-summary (policy &optional (stream *standard-output*))
  "Print a human-readable summary of a cache policy.

POLICY: A cache-policy struct
STREAM: Output stream (default: *standard-output*)"
  (format stream "~&Cache Policy: ~A~%" (cache-policy-name policy))
  (format stream "  TTL: ~D seconds (~,1F minutes)~%"
          (cache-policy-ttl policy)
          (/ (cache-policy-ttl policy) 60.0))
  (format stream "  ETag: ~A  Memory: ~A  Database: ~A~%"
          (cache-policy-use-etag-p policy)
          (cache-policy-cache-in-memory-p policy)
          (cache-policy-cache-in-db-p policy))
  (format stream "  Priority: ~D/10  Invalidate-on-write: ~A~%"
          (cache-policy-priority policy)
          (cache-policy-invalidate-on-write-p policy))
  (when (plusp (cache-policy-stale-while-revalidate policy))
    (format stream "  Stale-while-revalidate: ~D seconds~%"
            (cache-policy-stale-while-revalidate policy)))
  (values))

(defun endpoint-policy-summary (&optional (stream *standard-output*))
  "Print a summary of all per-endpoint policy overrides.

STREAM: Output stream (default: *standard-output*)"
  (format stream "~&Per-Endpoint Cache Policy Overrides~%")
  (format stream "~A~%" (make-string 50 :initial-element #\=))
  (let ((entries nil))
    (maphash (lambda (op-id policy)
               (push (cons op-id (cache-policy-name policy)) entries))
             *endpoint-policy-overrides*)
    (setf entries (sort entries #'string< :key #'car))
    (dolist (entry entries)
      (format stream "  ~A -> ~A~%" (car entry) (cdr entry))))
  (values))
