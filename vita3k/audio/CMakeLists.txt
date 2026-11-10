add_library(
    audio
    STATIC
    src/audio.cpp
    src/impl/sdl_audio.cpp)

target_include_directories(audio PUBLIC include)
target_link_libraries(audio PRIVATE util SDL3::SDL3)

# cubeb has no working iOS backend, so iOS uses SDL audio only (SDL is the default backend everywhere)
if(NOT IOS)
    target_sources(audio PRIVATE src/impl/cubeb_audio.cpp)
    target_link_libraries(audio PRIVATE cubeb)
    target_compile_definitions(audio PRIVATE VITA3K_HAS_CUBEB)
endif()
