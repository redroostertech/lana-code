add_executable(test_mylib test_mylib.c)
target_link_libraries(test_mylib PRIVATE mylib)

add_test(NAME test_mylib COMMAND test_mylib)
