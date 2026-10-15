import Darwin
let pid = Int32(CommandLine.arguments[1])!
print("PRIO_DARWIN_PROCESS =", PRIO_DARWIN_PROCESS, " PRIO_DARWIN_BG =", PRIO_DARWIN_BG)
errno = 0
var r = setpriority(rlim_t(PRIO_DARWIN_PROCESS), id_t(pid), PRIO_DARWIN_BG)
print("set BG  ->", r, r == 0 ? "OK" : String(cString: strerror(errno)))
errno = 0
r = getpriority(rlim_t(PRIO_DARWIN_PROCESS), id_t(pid))
print("get     ->", r, "(1 == w tle)")
errno = 0
r = setpriority(rlim_t(PRIO_DARWIN_PROCESS), id_t(pid), 0)
print("restore ->", r, r == 0 ? "OK" : String(cString: strerror(errno)))
errno = 0
print("get     ->", getpriority(rlim_t(PRIO_DARWIN_PROCESS), id_t(pid)), "(0 == normalny)")
