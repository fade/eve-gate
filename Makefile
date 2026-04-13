ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
PACKAGE=eve-gate
PACKAGEUTILS=eve-gate.app-utils
OUT=eve-gate
ENTRY=-main

$(OUT): buildapp *.lisp quicklisp-manifest.txt
	./buildapp  --manifest-file quicklisp-manifest.txt \
				--load-system asdf \
				--eval '(push "$(ROOT_DIR)/" asdf:*central-registry*)' \
				--load-system $(PACKAGE) \
				--eval '($(PACKAGEUTILS)::internal-disable-debugger)' \
				--output $(OUT) --entry $(PACKAGE):$(ENTRY)

quicklisp-manifest.txt: *.asd
	sbcl --non-interactive \
		--eval '(push #P"$(ROOT_DIR)/" asdf:*central-registry*)'\
		--eval '(ql:quickload "$(PACKAGE)")'\
		--eval '(ql:write-asdf-manifest-file "quicklisp-manifest.txt")'

buildapp:
	sbcl --eval '(ql:quickload "buildapp")' --eval '(buildapp:build-buildapp)' --non-interactive

# Run all tests
test:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(asdf:test-system :eve-gate)' \
		--eval '(sb-ext:quit)'

# Run only core tests
test-core:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(parachute:test :eve-gate/test/core)' \
		--eval '(sb-ext:quit)'

# Run only cache tests
test-cache:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(parachute:test :eve-gate/test/cache)' \
		--eval '(sb-ext:quit)'

# Run only type tests
test-types:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(parachute:test :eve-gate/test/types)' \
		--eval '(sb-ext:quit)'

# Run only API tests
test-api:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(parachute:test :eve-gate/test/api)' \
		--eval '(sb-ext:quit)'

# Run only concurrent tests
test-concurrent:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(parachute:test :eve-gate/test/concurrent)' \
		--eval '(sb-ext:quit)'

# Run only auth tests  
test-auth:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(parachute:test :eve-gate/test/auth)' \
		--eval '(sb-ext:quit)'

# Run only config tests
test-config:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(parachute:test :eve-gate/test/config)' \
		--eval '(sb-ext:quit)'

# Run only integration tests (no network required)
test-integration:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(parachute:test :eve-gate/test/integration)' \
		--eval '(sb-ext:quit)'

# Run live integration tests (requires network - uses Singularity test server)
test-live:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/live)' \
		--eval '(asdf:test-system :eve-gate/test/live)' \
		--eval '(sb-ext:quit)'

# Run performance tests
test-performance:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/performance)' \
		--eval '(asdf:test-system :eve-gate/test/performance)' \
		--eval '(sb-ext:quit)'

# Run benchmarks (more detailed performance analysis)
bench:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/dev)' \
		--eval '(eve-gate.dev.benchmarks:run-all-benchmarks)' \
		--eval '(sb-ext:quit)'

# Run all tests including live and performance
test-all:
	sbcl --non-interactive \
		--eval '(push #P"./" asdf:*central-registry*)' \
		--eval '(ql:quickload :eve-gate/test/all)' \
		--eval '(ql:quickload :eve-gate/test/performance)' \
		--eval '(asdf:test-system :eve-gate)' \
		--eval '(asdf:test-system :eve-gate/test/performance)' \
		--eval '(sb-ext:quit)'

clean:
	rm -f *.fasl $(OUT) buildapp quicklisp-manifest.txt
