#include <iostream>
#include <numeric>
#include <vector>

int main() {
    const std::vector<int> values{6, 12, 24};
    std::cout << std::accumulate(values.begin(), values.end(), 0) << '\n';
    return 0;
}
