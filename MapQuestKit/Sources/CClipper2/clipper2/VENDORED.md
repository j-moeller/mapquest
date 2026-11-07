# Vendored: Clipper2

* Upstream: https://github.com/AngusJohnson/Clipper2
* Version: tag `Clipper2_2.0.1` (commit 21ebba05db8894f0c7217ad35ea518080f324946)
* Files: `CPP/Clipper2Lib/include/clipper2/*.h` (without `clipper.export.h`) and
  `CPP/Clipper2Lib/src/*.cpp`, unmodified.
* Licence: Boost Software License 1.0 (see `LICENSE`).

MapQuest only talks to Clipper2 through the C interface in
`../include/MQClipper.h` (implemented in `../MQClipper.cpp`), so Swift does
not need C++ interoperability.
