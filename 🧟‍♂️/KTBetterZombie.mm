//
//  KTBetterZombie.m
//  🧟‍♂️
//
//  Created by Kam on 2020/8/19.
//

#import "KTBetterZombie.h"
#import <objc/runtime.h>

#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#include <execinfo.h>
#include <unordered_map>
#include <string>

#import <CommonCrypto/CommonDigest.h>
#import <os/lock.h>

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST  "__DATA_CONST"
#endif

using namespace std;

class RecordEntry {
private:
    vm_address_t *mBacktrace;
    int mBacktraceDepth;
public:
    RecordEntry(vm_address_t **backtrace, int backtraceDepth) {
        mBacktrace = (vm_address_t *)malloc(sizeof(vm_address_t *) * backtraceDepth);
        memcpy(mBacktrace, backtrace, backtraceDepth * sizeof(vm_address_t));
        mBacktraceDepth = backtraceDepth;
    }
    
    ~RecordEntry() {
        free(mBacktrace);
    }
    
    void Dump() {
        printf("Dumpping dealloc backtrace...\n");
        Dl_info symbolicated[mBacktraceDepth];
        for (int i = 0; i < mBacktraceDepth; i++) {
            
            dladdr((void *)mBacktrace[i], &symbolicated[i]);
        
            uintptr_t address = mBacktrace[i];
            Dl_info dlInfo = symbolicated[i];
            
            const char* fname = LastPath(dlInfo.dli_fname);
            uintptr_t offset = address - (uintptr_t)dlInfo.dli_saddr;
            
            const char* sname = dlInfo.dli_sname;
            printf("%-30s0x%012lx %s + %lu\n" ,fname, address, sname, offset);
        }
    }
    
    const char *LastPath(const char* const path) {
        if(path == NULL) return NULL;
        const char *lastFile = strrchr(path, '/');
        return lastFile == NULL ? path : lastFile + 1;
    }
};


static unordered_map<string, RecordEntry *> gMD5ToEntry;
static unordered_map<void *, string> gPtrToMD5;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

#define KTLock os_unfair_lock_lock(&gLock);
#define KTUnlock os_unfair_lock_unlock(&gLock);

typedef void(*KTIMP)(__unsafe_unretained id, SEL);

@implementation KTBetterZombie

+ (void)action {
    BOOL enableZombie = [NSProcessInfo.processInfo.environment objectForKey:@"NSZombieEnabled"].boolValue;
    
    if (!enableZombie) return; // only enable while zombie enable

    // when enable zombie, the orginal -dealloc method in NSObject
    // will be replaced by the -__dealloc_zombie method
    SEL deallocSel = NSSelectorFromString(@"dealloc");
    Method m = class_getInstanceMethod(NSObject.class, deallocSel);
    gOriginalDeallocIMP = (KTIMP)method_setImplementation(m, (IMP)ZombieDealloc);
    
    // rebind
    RebindClassRepsondsToSelector();
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    KTLock
    auto it = gPtrToMD5.find((__bridge void *)self);
    if (it != gPtrToMD5.end()) {
        string MD5 = it->second;
        auto itt = gMD5ToEntry.find(MD5);
        if (itt != gMD5ToEntry.end()) {
            itt->second->Dump();
        }
    }
    KTUnlock
    return nil; // let it go
}

static KTIMP gOriginalDeallocIMP;
static void ZombieDealloc(__unsafe_unretained id _self, SEL func){
    gOriginalDeallocIMP(_self, func);
    RecordBacktrace((__bridge void *)_self);
}

static void RebaseBacktrace(vm_address_t **stack, int depth) {
    for (int i = 0; i < depth; i++) {
        vm_address_t *stackAddrPtr = stack[i];
        Dl_info dfInfo;
        dladdr((void *)stackAddrPtr, &dfInfo);
        stack[i] = (vm_address_t *)dfInfo.dli_saddr;
    }
}

static void RecordBacktrace(void *objPtr) {
    static int max_stack_depth = 64; // that's enought, I guessssss....
    vm_address_t *stack[max_stack_depth];
    vm_address_t *rebasedStack[max_stack_depth];
    int depth = backtrace((void**)stack, max_stack_depth);
    memcpy(rebasedStack, stack, sizeof(stack));
    RebaseBacktrace(rebasedStack, depth);
    int skip = 2;
    KTLock
    string MD5Str = MD5ForStack(rebasedStack, skip, depth);
    if (gMD5ToEntry.find(MD5Str) == gMD5ToEntry.end()) { // not found
        RecordEntry *entry = new RecordEntry(stack + skip, depth - skip);
        gMD5ToEntry.insert(pair<string, RecordEntry *>(MD5Str, entry));
    }
    gPtrToMD5.insert(pair<void *, string>(objPtr, MD5Str));
    KTUnlock
}

static string MD5ForStack(vm_address_t **stack, int start, int end) {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5_CTX ctx;
    CC_MD5_Init(&ctx);
    CC_MD5_Update(&ctx, stack + start, (end - start) * sizeof(vm_address_t *));
    unsigned char r[CC_MD5_DIGEST_LENGTH] = {'\0'};
    CC_MD5_Final(r, &ctx);
#pragma GCC diagnostic pop
    string MD5Str((char *)r, 16);
    return MD5Str;
}


static BOOL (*gOriClassRespondsToSelector)(Class _Nullable cls, SEL _Nonnull sel);
static BOOL kTClassRespondsToSelector(Class _Nullable cls, SEL _Nonnull sel) {
    const char *className = class_getName(cls);
    const char *zombiePrefix = "_NSZombie_";
    size_t prefixLen = strlen(zombiePrefix);
    BOOL ret = gOriClassRespondsToSelector(cls, sel);
    if (!ret && strncmp(className, zombiePrefix, prefixLen) == 0) {
        // make the zombie can respond to -forwardingTargetForSelector:
        SEL forwardSel = @selector(forwardingTargetForSelector:);
        Method m = class_getInstanceMethod(KTBetterZombie.class, forwardSel);
        ret = class_addMethod(cls, forwardSel, method_getImplementation(m), method_getTypeEncoding(m));
    }
    return ret;
}

static void RebindClassRepsondsToSelector() {
    uint32 cfIndex = ImageIndexFromName("CoreFoundation");
    if (cfIndex == UINT32_MAX) return;

    const struct mach_header *header = _dyld_get_image_header(cfIndex);
    Dl_info info;
    if (dladdr(header, &info) == 0) return;
    
    void *replacmentFunction = (void *)kTClassRespondsToSelector;
    void **origFunctionPtr = (void **)&gOriClassRespondsToSelector;
    
    segment_command_t *curSegCmd;
    segment_command_t *linkeditSeg = NULL;
    struct symtab_command* symtabCmd = NULL;
    struct dysymtab_command* dysymtabCmd = NULL;

    intptr_t slide = _dyld_get_image_vmaddr_slide(cfIndex);

    uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint i = 0; i < header->ncmds; i++, cur += curSegCmd->cmdsize) {
        curSegCmd = (segment_command_t *)cur;
        if (curSegCmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(curSegCmd->segname, SEG_LINKEDIT) == 0) linkeditSeg = curSegCmd;
        } else if (curSegCmd->cmd == LC_SYMTAB) {
            symtabCmd = (struct symtab_command*)curSegCmd;
        } else if (curSegCmd->cmd == LC_DYSYMTAB) {
            dysymtabCmd = (struct dysymtab_command*)curSegCmd;
        }
    }

    if (!symtabCmd || !dysymtabCmd || !linkeditSeg || !dysymtabCmd->nindirectsyms) return;
    
    // Find base symbol/string table addresses
    uintptr_t linkeditBase = (uintptr_t)slide + linkeditSeg->vmaddr - linkeditSeg->fileoff;
    nlist_t *symtab = (nlist_t *)(linkeditBase + symtabCmd->symoff);
    char *strtab = (char *)(linkeditBase + symtabCmd->stroff);

    // Get indirect symbol table (array of uint32_t indices into symbol table)
    uint32_t *indirectSymtab = (uint32_t *)(linkeditBase + dysymtabCmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(mach_header_t);
    bool done = false;
    for (uint i = 0; i < header->ncmds; i++, cur += curSegCmd->cmdsize) {
        curSegCmd = (segment_command_t *)cur;
        if (curSegCmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(curSegCmd->segname, SEG_DATA) != 0 && strcmp(curSegCmd->segname, SEG_DATA_CONST) != 0) continue;
            for (uint j = 0; j < curSegCmd->nsects; j++) {
                section_t *sect = (section_t *)(cur + sizeof(segment_command_t)) + j;
                bool sym_ptr = (sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS || (sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS;
                if (sym_ptr) done = PerformRebinding(replacmentFunction, origFunctionPtr, sect, slide, symtab, strtab, indirectSymtab);
                if (done) break;
            }
        }
        if (done) break;
    }
}

static bool PerformRebinding(void *replaceFuncPtr, void **origFuncPtr, section_t *section, intptr_t slide, nlist_t *symtab, char *strtab, uint32_t *indirectSymtab) {
    bool success = false;
    const bool isDataConst = strcmp(section->segname, SEG_DATA_CONST) == 0;
    uint32_t *indirectSymbolIndices = indirectSymtab + section->reserved1;
    void **indirectSymbolBindings = (void **)((uintptr_t)slide + section->addr);
  
    vm_prot_t oldProtection = VM_PROT_READ;
    if (isDataConst) {
        oldProtection = GetProtection(section);
        mprotect(indirectSymbolBindings, section->size, PROT_READ | PROT_WRITE);
    }
    
    for (uint i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtabIndex = indirectSymbolIndices[i];
        if (symtabIndex == INDIRECT_SYMBOL_ABS || symtabIndex == INDIRECT_SYMBOL_LOCAL || symtabIndex == (INDIRECT_SYMBOL_LOCAL   | INDIRECT_SYMBOL_ABS)) continue;
        uint32_t strtabOffset = symtab[symtabIndex].n_un.n_strx;
        char *symbolName = strtab + strtabOffset;
        bool symbolNameLongerThanOne = symbolName[0] && symbolName[1];
                
        if (symbolNameLongerThanOne && strcmp(&symbolName[1], "class_respondsToSelector") == 0) {
            if (indirectSymbolBindings[i] != replaceFuncPtr) *origFuncPtr = indirectSymbolBindings[i];
            indirectSymbolBindings[i] = replaceFuncPtr;
            success = true;
            goto symbol_loop;
        }
    }
symbol_loop:
    if (isDataConst) {
        int protection = 0;
        if (oldProtection & VM_PROT_READ) protection |= PROT_READ;
        if (oldProtection & VM_PROT_WRITE) protection |= PROT_WRITE;
        if (oldProtection & VM_PROT_EXECUTE) protection |= PROT_EXEC;
        mprotect(indirectSymbolBindings, section->size, protection);
    }
    return success;
}

static uint32_t ImageIndexFromName(const char *targetName) {
    size_t targetNameLen = strlen(targetName);
    uint32_t cfIndex = UINT32_MAX;
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        const char *name = _dyld_get_image_name(i);
        size_t length = strlen(name);
        if (length < targetNameLen) continue;
        
        size_t matchCnt = 0;
        for (size_t j = length - 1; j >= 0; j--) {
            if (name[j] != targetName[targetNameLen - (length - j)]) break;
            matchCnt++;
        }
        if (matchCnt == targetNameLen) {
            cfIndex = i;
            break;
        }
    }
    return cfIndex;
}

static vm_prot_t GetProtection(void *sectionStart) {
    mach_port_t task = mach_task_self();
    vm_size_t size = 0;
    vm_address_t address = (vm_address_t)sectionStart;
    memory_object_name_t object;
#if __LP64__
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    vm_region_basic_info_data_64_t info;
    kern_return_t info_ret = vm_region_64(task, &address, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_64_t)&info, &count, &object);
#else
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT;
    vm_region_basic_info_data_t info;
    kern_return_t info_ret = vm_region(task, &address, &size, VM_REGION_BASIC_INFO, (vm_region_info_t)&info, &count, &object);
#endif
    if (info_ret == KERN_SUCCESS) {
        return info.protection;
    } else {
        return VM_PROT_READ;
    }
}

@end
