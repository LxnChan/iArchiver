# Decode-only UnRAR is linked exclusively into IA_SIDELOAD builds.
set(IA_UNRAR "${CMAKE_CURRENT_SOURCE_DIR}/../.deps/src/unrar")
set(IA_UNRAR_NAMES rar strlist strfn pathfn smallfn global file filefn filcreat
    archive arcread unicode system crypt crc rawread encname resource match timefn
    rdwrfn consio options errhnd rarvm secpassword rijndael getbits sha1 sha256
    blake2s hash extinfo extract volume list find unpack headers threadpool rs16
    cmddata ui largepage filestr scantree dll qopen)
if(WIN32)
    list(APPEND IA_UNRAR_NAMES isnt motw)
    set(IA_UNRAR_DEFINITIONS "RARDLL;_FILE_OFFSET_BITS=64;_LARGEFILE_SOURCE")
else()
    set(IA_UNRAR_DEFINITIONS "RARDLL;RAR_SMP;_FILE_OFFSET_BITS=64;_LARGEFILE_SOURCE")
endif()
set(IA_UNRAR_SOURCES)
foreach(IA_NAME IN LISTS IA_UNRAR_NAMES)
    list(APPEND IA_UNRAR_SOURCES "${IA_UNRAR}/${IA_NAME}.cpp")
endforeach()
set_source_files_properties(${IA_UNRAR_SOURCES} PROPERTIES COMPILE_DEFINITIONS "${IA_UNRAR_DEFINITIONS}")
target_sources(ArchiveCore PRIVATE RARBridge.cpp ${IA_UNRAR_SOURCES})
target_include_directories(ArchiveCore PRIVATE "${IA_UNRAR}")
if(WIN32)
    target_link_libraries(ArchiveCore PUBLIC shell32 comctl32)
endif()
