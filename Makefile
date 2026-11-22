.PHONY: build test runtest test.packages test.namespace test.network build.javascript test.javascript format format-check clean
build:
	opam exec -- dune build @all
test runtest:
	opam exec -- dune runtest
test.packages:
	for packages in hf-hub hf-hub,hf-hub-unix hf-hub,hf-hub-unix,hf-hub-lwt hf-hub,hf-hub-unix,hf-hub-async; do \
		opam exec -- dune build -p "$$packages" @install @runtest || exit $$?; \
	done
test.namespace:
	prefix=$$(mktemp -d) && \
	opam exec -- dune build @install && \
	opam exec -- dune install --prefix "$$prefix" hf-hub hf-hub-unix hf-hub-lwt hf-hub-async hf-hub-safetensors && \
	opam exec -- sh scripts/namespace-check.sh --fail --prefix Hf_hub --expect-libs scripts/namespace.expect "install=$$prefix/lib"
test.network:
	HF_HUB_TEST_NETWORK=1 opam exec -- dune exec test/network_test.exe
	opam exec -- dune exec test/tls_probe.exe -- lwt https://huggingface.co hub
	opam exec -- dune exec test/tls_probe.exe -- async https://huggingface.co hub
build.javascript:
	opam exec -- dune build --profile javascript javascript/jsoo/main.bc.js @hf-hub-melange
	npm --prefix javascript ci --ignore-scripts
	npm --prefix javascript run bundle
test.javascript: build.javascript
	npm --prefix javascript test
format:
	opam exec -- dune fmt
format-check:
	opam exec -- dune build @fmt
clean:
	opam exec -- dune clean
