# Host build of the portable frame-codec conformance test (no DevEco needed).
#   make test    # build and run
#   make clean
CXX ?= clang++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -O2 -I..

test: frame_codec_test
	./frame_codec_test

frame_codec_test: frame_codec_test.cpp ../frame_codec.cpp ../frame_codec.h
	$(CXX) $(CXXFLAGS) -o $@ frame_codec_test.cpp ../frame_codec.cpp

clean:
	rm -f frame_codec_test

.PHONY: test clean
