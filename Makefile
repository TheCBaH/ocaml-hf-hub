.PHONY: build test runtest test.packages test.network format format-check clean
build:
	opam exec -- dune build @all
test runtest:
	opam exec -- dune runtest
test.packages:
	for packages in hf-hub hf-hub,hf-hub-unix hf-hub,hf-hub-unix,hf-hub-lwt hf-hub,hf-hub-unix,hf-hub-async; do \
		opam exec -- dune build -p "$$packages" @install @runtest || exit $$?; \
	done
test.network:
	HF_HUB_TEST_NETWORK=1 opam exec -- dune exec test/network_test.exe
	opam exec -- dune exec test/tls_probe.exe -- lwt https://huggingface.co hub
	opam exec -- dune exec test/tls_probe.exe -- async https://huggingface.co hub
format:
	opam exec -- dune fmt
format-check:
	opam exec -- dune build @fmt
clean:
	opam exec -- dune clean
