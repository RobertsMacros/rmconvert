#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 2 || setpgid(0, 0) != 0) { perror("rmconvert worker group"); return 126; }
    execv(argv[1], argv + 1);
    perror("rmconvert converter");
    return 127;
}
