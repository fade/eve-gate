;;;; eve-http-client.lisp - Canonical production HTTP client for eve-gate
;;;;
;;;; `make-eve-http-client` is the entrypoint consumers should use when they
;;;; want a client that defends against ESI rate limits, honors Cache-Control
;;;; on responses, recovers from 420 Error Limited responses, and reuses
;;;; HTTP connections. It returns an `http-client` struct that the generated
;;;; ESI endpoint functions accept directly.
;;;;
;;;; Underneath, the middleware stack composed here is the union of:
;;;;   - `make-resilient-middleware-stack` (default + error-handling)
;;;;   - `make-throttling-middleware-stack` (token gate + response tracking + 420 retry)
;;;;   - `make-connection-pool-middleware` (Keep-Alive + compression headers)
;;;;   - `make-cache-middleware` when a cache-manager is supplied
;;;;
;;;; `make-http-client` in eve-gate.core remains the bare primitive for
;;;; tests and advanced consumers that want to compose the stack manually.
;;;; Application code in eve-gate and its consumers should prefer this
;;;; constructor.
;;;;
;;;; `make-throttled-http-client` is preserved as a deprecation alias and
;;;; emits a `simple-warning` on use; it will be removed in the next release.

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Production constructor
;;; ---------------------------------------------------------------------------

(defun make-eve-http-client (&key (base-url *esi-base-url*)
                                   (user-agent *user-agent*)
                                   (connect-timeout 10)
                                   (read-timeout *default-timeout*)
                                   (max-retries *default-retries*)
                                   cache-manager
                                   rate-limiter
                                   (rate-limit-timeout 30.0)
                                   (datasource "tranquility")
                                   (logging t)
                                   (log-headers nil)
                                   (log-body nil)
                                   (max-420-retries 3))
  "Create the canonical production HTTP client for eve-gate.

The returned `http-client` carries a middleware pipeline that:
  - Acquires a rate-limit token before each request and feeds X-ESI-Error-Limit-*
    headers back to the limiter on every response.
  - Automatically retries 420 Error Limited responses with exponential backoff.
  - Adds Keep-Alive and gzip compression headers for connection reuse.
  - Honors ESI Cache-Control / Expires on responses when CACHE-MANAGER is supplied,
    returning cached data for 304 Not Modified and short-circuiting still-fresh GETs.
  - Records error-handling statistics and circuit-breaker state.

KEYWORDS:
  BASE-URL              ESI base URL (default: *esi-base-url*)
  USER-AGENT            User-Agent header value
  CONNECT-TIMEOUT       TCP connect timeout in seconds (default: 10)
  READ-TIMEOUT          Response read timeout in seconds (default: *default-timeout*)
  MAX-RETRIES           HTTP-level transient-failure retry budget (default: *default-retries*)
  CACHE-MANAGER         A cache-manager from eve-gate.cache. When supplied, cache
                        middleware is installed. When nil, the client makes no
                        attempt to consult or populate a cache.
  RATE-LIMITER          An esi-rate-limiter. Defaults to the eve-gate.concurrent
                        global instance via `ensure-rate-limiter`.
  RATE-LIMIT-TIMEOUT    Maximum seconds to wait for a token at request time
                        (default: 30.0)
  DATASOURCE            ESI datasource header (default: \"tranquility\")
  LOGGING               Enable request/response logging (default: T)
  LOG-HEADERS           Include headers in log output (default: NIL)
  LOG-BODY              Include body excerpts in log output (default: NIL)
  MAX-420-RETRIES       Automatic retry attempts for 420 responses (default: 3)

RETURNS: an `http-client` struct.

EXAMPLE — production singleton, cache enabled:
  (defvar *cache* (eve-gate.cache:make-cache-manager :memory-cache-size 100000))
  (defvar *client* (eve-gate.concurrent:make-eve-http-client :cache-manager *cache*))
  (eve-gate.api:get-markets-region-id-orders *client* 10000002 :type-id 34)

EXAMPLE — production singleton, no cache (rate-limited but uncached):
  (eve-gate.concurrent:make-eve-http-client)"
  (let* ((limiter (or rate-limiter (ensure-rate-limiter)))
         (base-stack (make-resilient-middleware-stack
                       :datasource datasource
                       :logging logging
                       :log-headers log-headers
                       :log-body log-body
                       :rate-limit-callback
                       (lambda (remain reset)
                         (rate-limiter-record-response
                          limiter 200
                          :error-limit-remain remain
                          :error-limit-reset reset))))
         (throttle-stack (make-throttling-middleware-stack
                           :rate-limiter limiter
                           :timeout rate-limit-timeout
                           :max-420-retries max-420-retries))
         (stack (reduce #'add-middleware throttle-stack :initial-value base-stack))
         (stack (add-middleware stack (make-connection-pool-middleware)))
         (stack (if cache-manager
                    (add-middleware stack (make-cache-middleware cache-manager))
                    stack)))
    (make-http-client :base-url base-url
                      :user-agent user-agent
                      :connect-timeout connect-timeout
                      :timeout read-timeout
                      :retries max-retries
                      :middleware stack)))

;;; ---------------------------------------------------------------------------
;;; Deprecation alias
;;; ---------------------------------------------------------------------------

(defun make-throttled-http-client (&rest args &key &allow-other-keys)
  "Deprecated. Prefer `make-eve-http-client`.

The legacy throttled constructor predates the unified production entrypoint and
does not wire cache middleware. Its keyword set is a subset of `make-eve-http-client`'s
and is forwarded directly; existing call sites continue to work unchanged. This
shim will be removed in the next release."
  (warn "make-throttled-http-client is deprecated; use make-eve-http-client instead.")
  (apply #'make-eve-http-client args))
