.PHONY: build test runtest format format-check clean
build:
	opam exec -- dune build @all
test runtest:
	opam exec -- dune runtest
format:
	opam exec -- dune fmt
format-check:
	opam exec -- dune build @fmt
clean:
	opam exec -- dune clean
