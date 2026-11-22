// This host API probe does not execute a GPU kernel.
#include <ck/host/headers.hpp>
#include <fstream>
#include <iostream>
#include <string_view>

int main(int argc, char **argv) {
  if (argc != 2) {
    return 2;
  }
  const auto headers = ck::host::GetHeaders();
  constexpr std::string_view name = "ck/utility/type.hpp";
  if (!headers.contains(name) || headers.at(name).empty()) {
    return 3;
  }
  const auto bytes = headers.at(name);
  std::ofstream output(argv[1], std::ios::binary | std::ios::trunc);
  output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  output.close();
  if (!output) {
    return 4;
  }
  std::cout << "CK HOST HEADERS: " << headers.size() << '\n';
  return 0;
}
