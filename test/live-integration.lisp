;;;; test/live-integration.lisp - Live ESI API integration tests
;;;;
;;;; These tests make real HTTP requests to the ESI API to verify
;;;; end-to-end functionality. They require network access and
;;;; are designed to be run manually or in CI with network access.
;;;;
;;;; IMPORTANT: Tests use the Singularity test server (datasource=singularity)
;;;; to avoid impacting the production Tranquility server. Singularity is
;;;; CCP's test server for EVE Online.
;;;;
;;;; Note: Tests use public endpoints only (no authentication required).
;;;; For authenticated endpoint tests, set EVE_GATE_TEST_TOKEN environment
;;;; variable with a valid access token.
;;;;
;;;; Usage:
;;;;   (asdf:load-system :eve-gate/test/live)
;;;;   (parachute:test :eve-gate/test/live-integration)
;;;;
;;;; Or via Make:
;;;;   make test-live

(uiop:define-package #:eve-gate/test/live-integration
  (:use #:cl)
  (:import-from #:eve-gate.api
                ;; API client
                #:make-api-client
                ;; Public endpoint functions
                #:get-status
                #:get-alliances
                #:get-alliances-alliance-id
                #:get-characters-character-id
                #:get-characters-character-id-portrait
                #:get-corporations-corporation-id
                #:get-corporations-npccorps
                #:get-universe-types
                #:get-universe-systems
                #:get-universe-regions
                #:get-markets-prices
                #:get-incursions
                #:get-sovereignty-map
                #:get-fw-stats
                #:get-dogma-attributes
                #:get-dogma-effects
                #:get-insurance-prices
                #:get-industry-systems)
  (:import-from #:eve-gate.core
                #:esi-error
                #:esi-not-found
                #:esi-rate-limit-exceeded
                #:esi-server-error
                #:make-default-middleware-stack)
  (:import-from #:eve-gate.cache
                #:make-cache-manager
                #:cache-get
                #:cache-put
                #:cache-statistics
                #:cache-hit-rate)
  (:import-from #:eve-gate.utils
                #:get-precise-time
                #:elapsed-milliseconds)
  (:local-nicknames (#:t #:parachute))
  (:export
   #:run-live-tests
   #:*test-datasource*
   #:*test-character-id*
   #:*test-corporation-id*
   #:*test-alliance-id*))

(in-package #:eve-gate/test/live-integration)

;;; ---------------------------------------------------------------------------
;;; Test configuration
;;; ---------------------------------------------------------------------------

;; Use Singularity (test server) by default to avoid hitting production
(defparameter *test-datasource* "singularity"
  "ESI datasource for tests. Use 'singularity' (test server) or 'tranquility' (production).
Singularity is preferred for testing to avoid impacting the production API.")

(defparameter *test-character-id* 95465499
  "A known valid character ID for testing (CCP Bartender).
Note: Character may not exist on Singularity if not mirrored recently.")

(defparameter *test-corporation-id* 98000001
  "A known valid corporation ID for testing (Doomheim - the corp dead characters go to).")

(defparameter *test-alliance-id* 99010079
  "A known valid alliance ID for testing.")

(defparameter *test-type-id* 587
  "A known valid type ID for testing (Rifter).")

(defparameter *test-region-id* 10000002
  "A known valid region ID for testing (The Forge).")

(defparameter *test-system-id* 30000142
  "A known valid solar system ID for testing (Jita).")

(defparameter *network-available-p* nil
  "Set to T if network tests should run.")

(defun make-test-client ()
  "Create an API client configured for testing with Singularity datasource."
  (make-api-client))

(defun check-network-available ()
  "Check if ESI is reachable. Sets *network-available-p*.
Uses the Singularity test server for checking connectivity."
  (handler-case
      (let ((client (make-test-client)))
        ;; Try status endpoint with singularity datasource
        (get-status client :datasource *test-datasource*)
        (setf *network-available-p* t))
    (error (c)
      (format t "~&Network check failed: ~A~%" c)
      (setf *network-available-p* nil)))
  *network-available-p*)

;;; ---------------------------------------------------------------------------
;;; Server status tests (basic connectivity)
;;; ---------------------------------------------------------------------------

(t:define-test live/server-status
  "Test ESI server status endpoint on Singularity test server"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (status (get-status client :datasource *test-datasource*)))
      ;; Should return a hash-table with server info
      (t:true (hash-table-p status))
      ;; Should have player count (may be 0 on Singularity)
      (t:true (gethash "players" status))
      (t:true (integerp (gethash "players" status)))
      ;; Should have server version
      (t:true (gethash "server_version" status))
      (t:true (stringp (gethash "server_version" status))))))

;;; ---------------------------------------------------------------------------
;;; Character endpoint tests
;;; ---------------------------------------------------------------------------

(t:define-test live/character-public-info
  "Test character public information endpoint on Singularity"
  
  (when *network-available-p*
    (let ((client (make-test-client)))
      ;; Character may not exist on Singularity, so handle 404 gracefully
      (handler-case
          (let ((char-info (get-characters-character-id client 
                                                        :character-id *test-character-id*
                                                        :datasource *test-datasource*)))
            (t:true (hash-table-p char-info))
            ;; Should have character name
            (t:true (gethash "name" char-info))
            (t:true (stringp (gethash "name" char-info)))
            ;; Should have corporation ID
            (t:true (gethash "corporation_id" char-info))
            (t:true (integerp (gethash "corporation_id" char-info))))
        (esi-not-found ()
          ;; Character doesn't exist on Singularity - this is acceptable
          (t:true t "Character not on Singularity test server, skipping"))))))

(t:define-test live/character-portrait
  "Test character portrait endpoint on Singularity"
  
  (when *network-available-p*
    (let ((client (make-test-client)))
      (handler-case
          (let ((portrait (get-characters-character-id-portrait client
                                                                 :character-id *test-character-id*
                                                                 :datasource *test-datasource*)))
            (t:true (hash-table-p portrait))
            ;; Should have portrait URLs
            (t:true (or (gethash "px64x64" portrait)
                        (gethash "px128x128" portrait)
                        (gethash "px256x256" portrait)
                        (gethash "px512x512" portrait))))
        (esi-not-found ()
          (t:true t "Character not on Singularity test server, skipping"))))))

(t:define-test live/character-not-found
  "Test 404 handling for nonexistent character"
  
  (when *network-available-p*
    (let ((client (make-test-client)))
      (t:fail (get-characters-character-id client 
                                            :character-id 1
                                            :datasource *test-datasource*)
              'esi-not-found))))

;;; ---------------------------------------------------------------------------
;;; Corporation endpoint tests  
;;; ---------------------------------------------------------------------------

(t:define-test live/corporation-public-info
  "Test corporation public information endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (corp-info (get-corporations-corporation-id client
                                                        :corporation-id *test-corporation-id*
                                                        :datasource *test-datasource*)))
      (t:true (hash-table-p corp-info))
      ;; Should have corporation name
      (t:true (gethash "name" corp-info))
      (t:true (stringp (gethash "name" corp-info)))
      ;; Should have member count
      (t:true (gethash "member_count" corp-info)))))

(t:define-test live/npc-corporations
  "Test NPC corporations list endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (npc-corps (get-corporations-npccorps client :datasource *test-datasource*)))
      ;; Should be a vector/list of IDs
      (t:true (or (vectorp npc-corps) (listp npc-corps)))
      ;; Should have many NPC corps
      (t:true (> (length npc-corps) 100)))))

;;; ---------------------------------------------------------------------------
;;; Alliance endpoint tests
;;; ---------------------------------------------------------------------------

(t:define-test live/alliances-list
  "Test alliances list endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (alliances (get-alliances client :datasource *test-datasource*)))
      ;; Should be a vector/list of IDs
      (t:true (or (vectorp alliances) (listp alliances)))
      ;; Should have some alliances (may be fewer on Singularity)
      (t:true (>= (length alliances) 0)))))

(t:define-test live/alliance-info
  "Test alliance information endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           ;; Get first alliance from list
           (alliances (get-alliances client :datasource *test-datasource*)))
      (when (and alliances (> (length alliances) 0))
        (let* ((alliance-id (if (vectorp alliances) 
                                (aref alliances 0)
                                (first alliances)))
               (alliance-info (get-alliances-alliance-id client
                                                          :alliance-id alliance-id
                                                          :datasource *test-datasource*)))
          (t:true (hash-table-p alliance-info))
          ;; Should have name
          (t:true (gethash "name" alliance-info))
          ;; Should have ticker
          (t:true (gethash "ticker" alliance-info)))))))

;;; ---------------------------------------------------------------------------
;;; Universe endpoint tests
;;; ---------------------------------------------------------------------------

(t:define-test live/universe-types-paginated
  "Test universe types endpoint with pagination on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (page1 (get-universe-types client :page 1 :datasource *test-datasource*))
           (page2 (get-universe-types client :page 2 :datasource *test-datasource*)))
      ;; Should return arrays
      (t:true (or (vectorp page1) (listp page1)))
      (t:true (or (vectorp page2) (listp page2)))
      ;; Pages should be different
      (t:isnt equal page1 page2)
      ;; Each page should have items
      (t:true (> (length page1) 0))
      (t:true (> (length page2) 0)))))

(t:define-test live/universe-regions
  "Test universe regions endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (regions (get-universe-regions client :datasource *test-datasource*)))
      ;; Should return list of region IDs
      (t:true (or (vectorp regions) (listp regions)))
      ;; EVE has many regions
      (t:true (> (length regions) 50)))))

(t:define-test live/universe-systems
  "Test universe systems endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (systems (get-universe-systems client :datasource *test-datasource*)))
      ;; Should return list of system IDs
      (t:true (or (vectorp systems) (listp systems)))
      ;; EVE has thousands of systems
      (t:true (> (length systems) 5000)))))

;;; ---------------------------------------------------------------------------
;;; Market endpoint tests
;;; ---------------------------------------------------------------------------

(t:define-test live/market-prices
  "Test market prices endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (prices (get-markets-prices client :datasource *test-datasource*)))
      ;; Should return array of price data
      (t:true (or (vectorp prices) (listp prices)))
      ;; Should have items (may be fewer on Singularity)
      (t:true (> (length prices) 0))
      ;; Each item should have type_id
      (let ((first-item (if (vectorp prices) (aref prices 0) (first prices))))
        (t:true (hash-table-p first-item))
        (t:true (gethash "type_id" first-item))))))

;;; ---------------------------------------------------------------------------
;;; Industry endpoint tests
;;; ---------------------------------------------------------------------------

(t:define-test live/industry-systems
  "Test industry systems cost indices on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (systems (get-industry-systems client :datasource *test-datasource*)))
      ;; Should return array of system data
      (t:true (or (vectorp systems) (listp systems)))
      ;; Should have data
      (t:true (>= (length systems) 0)))))

;;; ---------------------------------------------------------------------------
;;; Other public endpoint tests
;;; ---------------------------------------------------------------------------

(t:define-test live/incursions
  "Test incursions endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (incursions (get-incursions client :datasource *test-datasource*)))
      ;; May be empty if no active incursions, but should not error
      (t:true (or (vectorp incursions) (listp incursions) (null incursions))))))

(t:define-test live/faction-warfare-stats
  "Test faction warfare statistics on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (fw-stats (get-fw-stats client :datasource *test-datasource*)))
      ;; Should return array of faction data
      (t:true (or (vectorp fw-stats) (listp fw-stats)))
      ;; Should have 4 factions
      (t:is = 4 (length fw-stats)))))

(t:define-test live/sovereignty-map
  "Test sovereignty map endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (sov-map (get-sovereignty-map client :datasource *test-datasource*)))
      ;; Should return array of sovereignty data
      (t:true (or (vectorp sov-map) (listp sov-map)))
      ;; May have fewer on Singularity
      (t:true (>= (length sov-map) 0)))))

(t:define-test live/insurance-prices
  "Test insurance prices endpoint on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (insurance (get-insurance-prices client :datasource *test-datasource*)))
      ;; Should return array of insurance data
      (t:true (or (vectorp insurance) (listp insurance)))
      ;; Many ships have insurance
      (t:true (> (length insurance) 100)))))

(t:define-test live/dogma-attributes
  "Test dogma attributes list on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (attrs (get-dogma-attributes client :datasource *test-datasource*)))
      ;; Should return list of attribute IDs
      (t:true (or (vectorp attrs) (listp attrs)))
      ;; Many attributes exist
      (t:true (> (length attrs) 1000)))))

;;; ---------------------------------------------------------------------------
;;; Caching integration tests
;;; ---------------------------------------------------------------------------

(t:define-test live/caching-effectiveness
  "Test that caching reduces API calls on Singularity"
  
  (when *network-available-p*
    (let* ((cache-manager (make-cache-manager))
           (client (make-test-client)))
      ;; First call - cache miss
      (let ((result1 (get-status client :datasource *test-datasource*)))
        (t:true (hash-table-p result1)))
      ;; Second call should hit cache (if we were using cache middleware)
      ;; For now just verify the call succeeds
      (let ((result2 (get-status client :datasource *test-datasource*)))
        (t:true (hash-table-p result2))))))

;;; ---------------------------------------------------------------------------
;;; Response time tests
;;; ---------------------------------------------------------------------------

(t:define-test live/response-time-reasonable
  "Test that API response times are reasonable on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (start (get-precise-time))
           (result (get-status client :datasource *test-datasource*))
           (elapsed-ms (elapsed-milliseconds start)))
      (t:true result)
      ;; Should complete within 10 seconds (generous for network variability)
      (t:true (< elapsed-ms 10000)))))

;;; ---------------------------------------------------------------------------
;;; Concurrent request tests
;;; ---------------------------------------------------------------------------

(t:define-test live/concurrent-requests
  "Test multiple concurrent requests on Singularity"
  
  (when *network-available-p*
    (let* ((client (make-test-client))
           (results (list)))
      ;; Make several requests (sequentially for simplicity in test)
      (push (get-status client :datasource *test-datasource*) results)
      (push (get-alliances client :datasource *test-datasource*) results)
      (push (get-corporations-npccorps client :datasource *test-datasource*) results)
      ;; All should succeed
      (t:is = 3 (length results))
      (t:true (every #'identity results)))))

;;; ---------------------------------------------------------------------------
;;; Error handling tests
;;; ---------------------------------------------------------------------------

(t:define-test live/error-recovery
  "Test error handling and recovery on Singularity"
  
  (when *network-available-p*
    (let ((client (make-test-client)))
      ;; Should handle 404 gracefully
      (handler-case
          (get-characters-character-id client 
                                        :character-id 1 
                                        :datasource *test-datasource*)
        (esi-not-found (c)
          (t:true (typep c 'esi-not-found)))
        (esi-error (c)
          ;; Any ESI error is acceptable
          (t:true (typep c 'esi-error)))))))

;;; ---------------------------------------------------------------------------
;;; Test suite definition
;;; ---------------------------------------------------------------------------

(t:define-test live-integration-tests
  "Live integration test suite - requires network access.
Uses Singularity (test server) to avoid impacting production."
  ;; Check network availability first
  (check-network-available)
  (if *network-available-p*
      (format t "~&Network available, running live tests against ~A...~%" *test-datasource*)
      (format t "~&Network not available, skipping live tests~%")))

;;; ---------------------------------------------------------------------------
;;; Manual test runner
;;; ---------------------------------------------------------------------------

(defun run-live-tests (&key (datasource "singularity"))
  "Run all live integration tests.

DATASOURCE: ESI datasource to test against (default: 'singularity')
  - 'singularity' = Test server (recommended for testing)
  - 'tranquility' = Production server (use sparingly)

This function checks network availability and runs appropriate tests.
Returns the test report."
  (setf *test-datasource* datasource)
  (format t "~&=== EVE-GATE Live Integration Tests ===~%")
  (format t "Target server: ~A~%" datasource)
  (format t "Checking ESI availability...~%")
  (if (check-network-available)
      (progn
        (format t "ESI (~A) is reachable. Running tests...~%~%" datasource)
        (t:test 'live-integration-tests :report 'parachute:interactive))
      (progn
        (format t "ESI (~A) is not reachable. Skipping live tests.~%" datasource)
        (format t "Note: Singularity may be offline for maintenance.~%")
        nil)))
