set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -Wall")

add_library(modbruteguard SHARED
    modbruteguard.cpp
)

set_target_properties(modbruteguard PROPERTIES PREFIX "")
