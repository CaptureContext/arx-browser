#include <cassert>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

namespace base {
struct FilePath {
  std::filesystem::path path;
  FilePath()=default;
  FilePath(std::filesystem::path value):path(std::move(value)) {}
  FilePath AppendASCII(const std::string& leaf) const { return FilePath(path/leaf); }
  bool empty() const { return path.empty(); }
};
bool fail_copy=false;
bool CreateDirectory(const FilePath& path) {
  return std::filesystem::create_directories(path.path) || std::filesystem::is_directory(path.path);
}
bool SetPosixFilePermissions(const FilePath&,int mode) { assert(mode==0700); return true; }
bool WriteFile(const FilePath& path,const std::string& value) {
  std::ofstream stream(path.path,std::ios::binary); stream<<value; return stream.good();
}
bool CopyFile(const FilePath& source,const FilePath& target) {
  if (fail_copy && source.path.filename()=="popup.js") return false;
  return std::filesystem::copy_file(source.path,target.path);
}
FilePath MakeAbsoluteFilePath(const FilePath& path) { return FilePath(std::filesystem::canonical(path.path)); }
bool ReadFileToStringWithMaxSize(const FilePath& path,std::string* output,size_t maximum) {
  std::ifstream input(path.path,std::ios::binary);
  if (!input) return false;
  output->assign(std::istreambuf_iterator<char>(input),{});
  return output->size()<=maximum;
}
}
namespace crypto::keypair {
struct PrivateKey { static int GenerateRsa2048() { static int key=0; return ++key; } };
}
namespace zip {
bool Zip(const base::FilePath& source,const base::FilePath& target,bool) {
  for (const char* name:{"manifest.json","worker.js","content.js","rules.json"})
    assert(std::filesystem::is_regular_file(source.path/name));
  return base::WriteFile(target,source.path.string());
}
}
namespace crx_file {
enum class CreatorResult { OK, FAILED };
CreatorResult Create(const base::FilePath& output,const base::FilePath& zip,int key) {
  return base::WriteFile(output,"verified-peer-key="+std::to_string(key)+zip.path.string())
      ? CreatorResult::OK : CreatorResult::FAILED;
}
}
struct ArxEngineCallbacks {};
struct BridgeState {
  int calls=0;
  std::map<uint32_t,std::vector<uint8_t>> packages;
  void Initialize(const ArxEngineCallbacks&,bool,const base::FilePath&,
      std::map<uint32_t,std::vector<uint8_t>> values,const std::string&) { ++calls; packages=std::move(values); }
};
BridgeState& Bridge() { static BridgeState bridge; return bridge; }
int messaging_calls=0;
bool messaging_available=false;
bool InitializeNativeMessagingFixture(const base::FilePath&,const base::FilePath&) {
  ++messaging_calls; return messaging_available;
}
// COMPILED_CONSTANTS
// PREPARE_SIGNED
// INITIALIZE
int main(int argc,char** argv) {
  assert(argc==2);
  const base::FilePath root{std::filesystem::path(argv[1])};
  assert(InitializeExtensions({},true,root.AppendASCII("signed"),true,{}));
  assert(messaging_calls==0); // signed host need not bundle a native-message executable
  assert(Bridge().packages.size()==4);
  assert(Bridge().packages.at(0)!=Bridge().packages.at(3)); // actual corrupt-variant construction
  const int signed_calls=Bridge().calls;
  messaging_available=true;
  assert(InitializeExtensions({},true,root.AppendASCII("unpacked"),false,{}));
  assert(messaging_calls==1 && Bridge().calls==signed_calls+1 && Bridge().packages.empty());
  messaging_available=false;
  assert(!InitializeExtensions({},true,root.AppendASCII("missing-host"),false,{}));
  assert(messaging_calls==2 && Bridge().calls==signed_calls+1);
  base::fail_copy=true;
  assert(!InitializeExtensions({},true,root.AppendASCII("missing-update-asset"),true,{}));
  assert(messaging_calls==2 && Bridge().calls==signed_calls+1);
  assert(!std::filesystem::exists(root.AppendASCII("missing-update-asset").AppendASCII("install-v2.crx").path));
}
