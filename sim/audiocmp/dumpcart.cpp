// Print a cart's Lua source (decoded by fake-08).
#include <cstdio>
#include <vector>
#include "cart.h"
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");
    std::vector<unsigned char> d;
    int c;
    while ((c = fgetc(f)) != EOF) d.push_back(c);
    Cart cart(d.data(), d.size());
    fputs(cart.LuaString.c_str(), stdout);
}
