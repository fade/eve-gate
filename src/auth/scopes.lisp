;;;; scopes.lisp - ESI scope validation and management for eve-gate
;;;;
;;;; Defines all 57 EVE ESI OAuth 2.0 scopes, organized by category.
;;;; Provides validation, querying, and set-operation utilities for working
;;;; with scope collections throughout the authentication system.
;;;;
;;;; ESI scopes follow the pattern: esi-<category>.<operation>.<version>
;;;; e.g., "esi-characters.read_standings.v1"
;;;;
;;;; The canonical scope list is maintained as a structured alist mapping
;;;; each scope string to metadata (category, description, required-for).
;;;; All public functions operate on scope strings or lists thereof.
;;;;
;;;; Design: Pure functions on immutable data. No state, no side effects.
;;;; The scope registry is a defparameter that can be rebound for testing.

(in-package #:eve-gate.auth)

;;; ---------------------------------------------------------------------------
;;; Scope category keywords
;;; ---------------------------------------------------------------------------

(defparameter *scope-categories*
  '(:assets :bookmarks :calendar :characters :clones :contracts
    :corporations :fittings :fleets :industry :killmails :location
    :mail :markets :opportunities :planets :search :skills :ui
    :universe :wallet :alliances)
  "All ESI scope categories as keyword symbols.")

;;; ---------------------------------------------------------------------------
;;; Complete ESI scope registry
;;; ---------------------------------------------------------------------------

(defparameter *esi-scope-registry*
  '(;; Assets
    ("esi-assets.read_assets.v1"
     :category :assets
     :description "Read character assets")
    ("esi-assets.read_corporation_assets.v1"
     :category :assets
     :description "Read corporation assets")

    ;; Bookmarks
    ("esi-bookmarks.read_character_bookmarks.v1"
     :category :bookmarks
     :description "Read character bookmarks")
    ("esi-bookmarks.read_corporation_bookmarks.v1"
     :category :bookmarks
     :description "Read corporation bookmarks")

    ;; Calendar
    ("esi-calendar.read_calendar_events.v1"
     :category :calendar
     :description "Read calendar events")
    ("esi-calendar.respond_calendar_events.v1"
     :category :calendar
     :description "Respond to calendar events")

    ;; Characters
    ("esi-characters.read_agents_research.v1"
     :category :characters
     :description "Read character agent research")
    ("esi-characters.read_blueprints.v1"
     :category :characters
     :description "Read character blueprints")
    ("esi-characters.read_contacts.v1"
     :category :characters
     :description "Read character contacts")
    ("esi-characters.write_contacts.v1"
     :category :characters
     :description "Write character contacts")
    ("esi-characters.read_corporation_roles.v1"
     :category :characters
     :description "Read character corporation roles")
    ("esi-characters.read_fatigue.v1"
     :category :characters
     :description "Read character jump fatigue")
    ("esi-characters.read_fw_stats.v1"
     :category :characters
     :description "Read character faction warfare stats")
    ("esi-characters.read_loyalty.v1"
     :category :characters
     :description "Read character loyalty points")
    ("esi-characters.read_medals.v1"
     :category :characters
     :description "Read character medals")
    ("esi-characters.read_notifications.v1"
     :category :characters
     :description "Read character notifications")
    ("esi-characters.read_opportunities.v1"
     :category :characters
     :description "Read character opportunities")
    ("esi-characters.read_standings.v1"
     :category :characters
     :description "Read character standings")
    ("esi-characters.read_titles.v1"
     :category :characters
     :description "Read character titles")

    ;; Clones
    ("esi-clones.read_clones.v1"
     :category :clones
     :description "Read character clones")
    ("esi-clones.read_implants.v1"
     :category :clones
     :description "Read character active implants")

    ;; Contracts
    ("esi-contracts.read_character_contracts.v1"
     :category :contracts
     :description "Read character contracts")
    ("esi-contracts.read_corporation_contracts.v1"
     :category :contracts
     :description "Read corporation contracts")

    ;; Corporations
    ("esi-corporations.read_blueprints.v1"
     :category :corporations
     :description "Read corporation blueprints")
    ("esi-corporations.read_contacts.v1"
     :category :corporations
     :description "Read corporation contacts")
    ("esi-corporations.read_container_logs.v1"
     :category :corporations
     :description "Read corporation container logs")
    ("esi-corporations.read_corporation_membership.v1"
     :category :corporations
     :description "Read corporation membership")
    ("esi-corporations.read_divisions.v1"
     :category :corporations
     :description "Read corporation divisions")
    ("esi-corporations.read_facilities.v1"
     :category :corporations
     :description "Read corporation facilities")
    ("esi-corporations.read_fw_stats.v1"
     :category :corporations
     :description "Read corporation faction warfare stats")
    ("esi-corporations.read_medals.v1"
     :category :corporations
     :description "Read corporation medals")
    ("esi-corporations.read_standings.v1"
     :category :corporations
     :description "Read corporation standings")
    ("esi-corporations.read_starbases.v1"
     :category :corporations
     :description "Read corporation starbases (POSes)")
    ("esi-corporations.read_structures.v1"
     :category :corporations
     :description "Read corporation structures")
    ("esi-corporations.read_titles.v1"
     :category :corporations
     :description "Read corporation titles")
    ("esi-corporations.track_members.v1"
     :category :corporations
     :description "Track corporation member locations and ships")

    ;; Fittings
    ("esi-fittings.read_fittings.v1"
     :category :fittings
     :description "Read character fittings")
    ("esi-fittings.write_fittings.v1"
     :category :fittings
     :description "Write character fittings")

    ;; Fleets
    ("esi-fleets.read_fleet.v1"
     :category :fleets
     :description "Read fleet information")
    ("esi-fleets.write_fleet.v1"
     :category :fleets
     :description "Write fleet information")

    ;; Industry
    ("esi-industry.read_character_jobs.v1"
     :category :industry
     :description "Read character industry jobs")
    ("esi-industry.read_character_mining.v1"
     :category :industry
     :description "Read character mining ledger")
    ("esi-industry.read_corporation_jobs.v1"
     :category :industry
     :description "Read corporation industry jobs")
    ("esi-industry.read_corporation_mining.v1"
     :category :industry
     :description "Read corporation mining extractions and observers")

    ;; Killmails
    ("esi-killmails.read_killmails.v1"
     :category :killmails
     :description "Read character killmails")
    ("esi-killmails.read_corporation_killmails.v1"
     :category :killmails
     :description "Read corporation killmails")

    ;; Location
    ("esi-location.read_location.v1"
     :category :location
     :description "Read character location")
    ("esi-location.read_online.v1"
     :category :location
     :description "Read character online status")
    ("esi-location.read_ship_type.v1"
     :category :location
     :description "Read character current ship")

    ;; Mail
    ("esi-mail.organize_mail.v1"
     :category :mail
     :description "Organize character mail (labels, read status)")
    ("esi-mail.read_mail.v1"
     :category :mail
     :description "Read character mail")
    ("esi-mail.send_mail.v1"
     :category :mail
     :description "Send mail on behalf of character")

    ;; Markets
    ("esi-markets.read_character_orders.v1"
     :category :markets
     :description "Read character market orders")
    ("esi-markets.read_corporation_orders.v1"
     :category :markets
     :description "Read corporation market orders")
    ("esi-markets.structure_markets.v1"
     :category :markets
     :description "Read structure market orders")

    ;; Planets (Planetary Interaction)
    ("esi-planets.manage_planets.v1"
     :category :planets
     :description "Manage character planetary colonies")
    ("esi-planets.read_customs_offices.v1"
     :category :planets
     :description "Read corporation customs offices")

    ;; Search
    ("esi-search.search_structures.v1"
     :category :search
     :description "Search for structures")

    ;; Skills
    ("esi-skills.read_skillqueue.v1"
     :category :skills
     :description "Read character skill queue")
    ("esi-skills.read_skills.v1"
     :category :skills
     :description "Read character skills")

    ;; UI
    ("esi-ui.open_window.v1"
     :category :ui
     :description "Open in-game UI windows")
    ("esi-ui.write_waypoint.v1"
     :category :ui
     :description "Set in-game autopilot waypoints")

    ;; Universe
    ("esi-universe.read_structures.v1"
     :category :universe
     :description "Read structure information")

    ;; Wallet
    ("esi-wallet.read_character_wallet.v1"
     :category :wallet
     :description "Read character wallet balance and journal")
    ("esi-wallet.read_corporation_wallets.v1"
     :category :wallet
     :description "Read corporation wallet balances and journals"))
  "Complete registry of all ESI OAuth 2.0 scopes.
Each entry is (scope-string . plist) where plist contains:
  :CATEGORY - keyword identifying the scope's functional area
  :DESCRIPTION - human-readable description of what the scope grants

This list is authoritative for the eve-gate library and should be
updated when CCP adds or removes scopes from the ESI.")

;;; ---------------------------------------------------------------------------
;;; Derived scope list (cached for performance)
;;; ---------------------------------------------------------------------------

(defparameter *available-scopes*
  (mapcar #'car *esi-scope-registry*)
  "List of all valid ESI scope strings.
Derived from *ESI-SCOPE-REGISTRY* at load time.")

(defparameter *scope-count* (length *available-scopes*)
  "Total number of known ESI scopes.")

;;; ---------------------------------------------------------------------------
;;; Scope validation
;;; ---------------------------------------------------------------------------

(defun valid-scope-p (scope)
  "Return T if SCOPE is a recognized ESI scope string.

SCOPE: A string to validate

Example:
  (valid-scope-p \"esi-skills.read_skills.v1\") => T
  (valid-scope-p \"esi-nonsense.fake_scope.v1\") => NIL"
  (and (stringp scope)
       (assoc scope *esi-scope-registry* :test #'string=)
       t))

(defun validate-scopes (scopes)
  "Validate a list of scope strings against the ESI scope registry.
Returns the validated list if all scopes are valid.
Signals an error listing any invalid scopes found.

SCOPES: A list of scope strings to validate

Returns: The input list (for chaining) if all valid.

Example:
  (validate-scopes '(\"esi-skills.read_skills.v1\"
                     \"esi-wallet.read_character_wallet.v1\"))
  => (\"esi-skills.read_skills.v1\" \"esi-wallet.read_character_wallet.v1\")"
  (let ((invalid (remove-if #'valid-scope-p scopes)))
    (when invalid
      (error "Invalid ESI scope~P: ~{~A~^, ~}~%Valid scopes: ~{~A~^, ~}"
             (length invalid) invalid *available-scopes*))
    scopes))

(defun scope-required-p (scope granted-scopes)
  "Check whether SCOPE is present in the GRANTED-SCOPES list.
Used to verify that a required scope was authorized before making an API call.

SCOPE: A scope string to check
GRANTED-SCOPES: List of scope strings that were authorized

Returns: T if scope is present in granted-scopes, NIL otherwise.

Example:
  (scope-required-p \"esi-skills.read_skills.v1\"
                    '(\"esi-skills.read_skills.v1\"
                      \"esi-wallet.read_character_wallet.v1\"))
  => T"
  (and (member scope granted-scopes :test #'string=)
       t))

;;; ---------------------------------------------------------------------------
;;; Scope metadata queries
;;; ---------------------------------------------------------------------------

(defun scope-info (scope)
  "Return the metadata plist for SCOPE, or NIL if not a valid scope.

SCOPE: An ESI scope string

Returns: A plist with :CATEGORY and :DESCRIPTION, or NIL.

Example:
  (scope-info \"esi-skills.read_skills.v1\")
  => (:CATEGORY :SKILLS :DESCRIPTION \"Read character skills\")"
  (cdr (assoc scope *esi-scope-registry* :test #'string=)))

(defun scope-category (scope)
  "Return the category keyword for SCOPE, or NIL.

SCOPE: An ESI scope string

Example:
  (scope-category \"esi-skills.read_skills.v1\") => :SKILLS"
  (getf (scope-info scope) :category))

(defun scope-description (scope)
  "Return the human-readable description for SCOPE, or NIL.

SCOPE: An ESI scope string

Example:
  (scope-description \"esi-skills.read_skills.v1\")
  => \"Read character skills\""
  (getf (scope-info scope) :description))

;;; ---------------------------------------------------------------------------
;;; Scope collection operations
;;; ---------------------------------------------------------------------------

(defun scopes-by-category (category)
  "Return all scope strings belonging to CATEGORY.

CATEGORY: A keyword symbol (e.g., :skills, :wallet, :corporations)

Returns: List of scope strings in that category.

Example:
  (scopes-by-category :skills)
  => (\"esi-skills.read_skillqueue.v1\" \"esi-skills.read_skills.v1\")"
  (loop for (scope . plist) in *esi-scope-registry*
        when (eq (getf plist :category) category)
        collect scope))

(defun all-read-scopes ()
  "Return all ESI scopes that grant read access.
Matches scopes containing 'read_' in their name.

Returns: List of read-only scope strings."
  (remove-if-not (lambda (scope)
                   (search "read_" scope))
                 *available-scopes*))

(defun all-write-scopes ()
  "Return all ESI scopes that grant write access.
Matches scopes containing 'write_', 'manage_', 'send_', 'organize_',
'respond_', or 'track_' in their name.

Returns: List of write/modify scope strings."
  (remove-if-not (lambda (scope)
                   (or (search "write_" scope)
                       (search "manage_" scope)
                       (search "send_" scope)
                       (search "organize_" scope)
                       (search "respond_" scope)
                       (search "track_" scope)
                       (search "open_" scope)))
                 *available-scopes*))

(defun character-scopes ()
  "Return all scopes relevant to character-level data access.
Excludes corporation-specific scopes.

Returns: List of character scope strings."
  (remove-if (lambda (scope)
               (or (search "corporation" scope)
                   (search "customs_offices" scope)))
             *available-scopes*))

(defun corporation-scopes ()
  "Return all scopes relevant to corporation-level data access.

Returns: List of corporation scope strings."
  (remove-if-not (lambda (scope)
                   (or (search "corporation" scope)
                       (search "customs_offices" scope)
                       (search "track_members" scope)
                       (search "read_starbases" scope)
                       (search "read_structures" scope)
                       (search "read_facilities" scope)
                       (search "read_divisions" scope)
                       (search "read_container_logs" scope)))
                 *available-scopes*))

;;; ---------------------------------------------------------------------------
;;; Scope set operations
;;; ---------------------------------------------------------------------------

(defun merge-scopes (&rest scope-lists)
  "Merge multiple lists of scopes into a single deduplicated list.
Order is preserved (first occurrence wins).

SCOPE-LISTS: Any number of lists of scope strings.

Returns: A deduplicated list of scope strings.

Example:
  (merge-scopes '(\"esi-skills.read_skills.v1\")
                '(\"esi-skills.read_skills.v1\"
                  \"esi-wallet.read_character_wallet.v1\"))
  => (\"esi-skills.read_skills.v1\" \"esi-wallet.read_character_wallet.v1\")"
  (let ((seen (make-hash-table :test #'equal))
        (result nil))
    (dolist (scope-list scope-lists (nreverse result))
      (dolist (scope scope-list)
        (unless (gethash scope seen)
          (setf (gethash scope seen) t)
          (push scope result))))))

(defun subtract-scopes (base-scopes &rest removal-lists)
  "Remove scopes in REMOVAL-LISTS from BASE-SCOPES.

BASE-SCOPES: Starting list of scope strings
REMOVAL-LISTS: Lists of scope strings to remove

Returns: BASE-SCOPES with specified scopes removed.

Example:
  (subtract-scopes '(\"esi-skills.read_skills.v1\"
                     \"esi-wallet.read_character_wallet.v1\")
                   '(\"esi-skills.read_skills.v1\"))
  => (\"esi-wallet.read_character_wallet.v1\")"
  (let ((removals (make-hash-table :test #'equal)))
    (dolist (removal-list removal-lists)
      (dolist (scope removal-list)
        (setf (gethash scope removals) t)))
    (remove-if (lambda (scope) (gethash scope removals))
               base-scopes)))

(defun missing-scopes (required-scopes granted-scopes)
  "Return the scopes in REQUIRED-SCOPES that are not in GRANTED-SCOPES.
Useful for checking whether a token has sufficient authorization.

REQUIRED-SCOPES: List of scope strings needed
GRANTED-SCOPES: List of scope strings the token has

Returns: List of missing scope strings, or NIL if all are present.

Example:
  (missing-scopes '(\"esi-skills.read_skills.v1\"
                    \"esi-wallet.read_character_wallet.v1\")
                  '(\"esi-skills.read_skills.v1\"))
  => (\"esi-wallet.read_character_wallet.v1\")"
  (remove-if (lambda (scope)
               (member scope granted-scopes :test #'string=))
             required-scopes))

(defun sufficient-scopes-p (required-scopes granted-scopes)
  "Return T if GRANTED-SCOPES contains all of REQUIRED-SCOPES.

REQUIRED-SCOPES: List of scope strings needed
GRANTED-SCOPES: List of scope strings the token has

Returns: T if all required scopes are granted.

Example:
  (sufficient-scopes-p '(\"esi-skills.read_skills.v1\")
                       '(\"esi-skills.read_skills.v1\"
                         \"esi-wallet.read_character_wallet.v1\"))
  => T"
  (null (missing-scopes required-scopes granted-scopes)))

;;; ---------------------------------------------------------------------------
;;; Scope string formatting  
;;; ---------------------------------------------------------------------------

(defun format-scopes-for-oauth (scopes)
  "Format a list of scope strings into the space-separated string
required by the OAuth 2.0 authorization request.

SCOPES: List of scope strings

Returns: A single space-separated string.

Example:
  (format-scopes-for-oauth '(\"esi-skills.read_skills.v1\"
                             \"esi-wallet.read_character_wallet.v1\"))
  => \"esi-skills.read_skills.v1 esi-wallet.read_character_wallet.v1\""
  (format nil "~{~A~^ ~}" scopes))

(defun parse-scope-string (scope-string)
  "Parse a space-separated scope string (as returned by OAuth servers)
into a list of individual scope strings.

SCOPE-STRING: A string with space-separated scopes

Returns: A list of scope strings.

Example:
  (parse-scope-string \"esi-skills.read_skills.v1 esi-wallet.read_character_wallet.v1\")
  => (\"esi-skills.read_skills.v1\" \"esi-wallet.read_character_wallet.v1\")"
  (when (and scope-string (plusp (length scope-string)))
    (cl-ppcre:split "\\s+" scope-string)))

;;; ---------------------------------------------------------------------------
;;; Scope summary (REPL-friendly)
;;; ---------------------------------------------------------------------------

(defun scope-summary (&optional scopes)
  "Print a human-readable summary of SCOPES (or all scopes if NIL).
Grouped by category with descriptions. Useful at the REPL.

SCOPES: Optional list of scope strings to summarize. Defaults to all.

Returns: NIL (output is printed)."
  (let* ((scope-list (or scopes *available-scopes*))
         (by-category (make-hash-table)))
    ;; Group by category
    (dolist (scope scope-list)
      (let ((cat (or (scope-category scope) :unknown)))
        (push scope (gethash cat by-category))))
    ;; Print by category
    (format t "~&ESI Scopes (~D total):~%" (length scope-list))
    (maphash (lambda (category scope-list)
               (format t "~%  ~A (~D):~%" category (length scope-list))
               (dolist (scope (sort (copy-list scope-list) #'string<))
                 (format t "    ~A~@[ - ~A~]~%"
                         scope (scope-description scope))))
             by-category)
    (values)))
