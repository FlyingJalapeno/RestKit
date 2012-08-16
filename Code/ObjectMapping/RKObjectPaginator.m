//
//  RKObjectPaginator.m
//  RestKit
//
//  Created by Blake Watters on 12/29/11.
//  Copyright (c) 2009-2012 RestKit. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "RKObjectPaginator.h"
#import "RKManagedObjectLoader.h"
#import "RKObjectMappingOperation.h"
#import "SOCKit.h"
#import "RKLog.h"

static NSUInteger RKObjectPaginatorDefaultPerPage = 25;
static NSUInteger RKObjectPaginatorMaxConcurrentPages = 4;

// Private interface
@interface RKObjectPaginator () <RKObjectLoaderDelegate>

@property (nonatomic, retain) NSMutableArray *pageLoaders;

@property (nonatomic, readonly) NSUInteger currentPage;

@end

@implementation RKObjectPaginator

@synthesize patternURL;
@synthesize perPage;
@synthesize pageCount;
@synthesize objectCount;
@synthesize mappingProvider;
@synthesize delegate;
@synthesize objectStore;
@synthesize configurationDelegate;
@synthesize onDidLoadObjectsForPage;
@synthesize onDidFailWithError;
@synthesize pageLoaders;
@synthesize currentPage;

+ (id)paginatorWithPatternURL:(RKURL *)aPatternURL mappingProvider:(RKObjectMappingProvider *)aMappingProvider {
    return [[[self alloc] initWithPatternURL:aPatternURL mappingProvider:aMappingProvider] autorelease];
}

- (id)initWithPatternURL:(RKURL *)aPatternURL mappingProvider:(RKObjectMappingProvider *)aMappingProvider {
    self = [super init];
    if (self) {
        patternURL = [aPatternURL copy];
        mappingProvider = [aMappingProvider retain];
        pageLoaders = [[NSMutableArray array] retain];
        pageCount = NSUIntegerMax;
        objectCount = NSUIntegerMax;
        currentPage = NSUIntegerMax;
        perPage = RKObjectPaginatorDefaultPerPage;
    }

    return self;
}

- (void)dealloc {
    
    [self cancel];
       
    [pageLoaders release];
    pageLoaders = nil;
    delegate = nil;
    configurationDelegate = nil;
    [patternURL release];
    patternURL = nil;
    [mappingProvider release];
    mappingProvider = nil;
    [objectStore release];
    objectStore = nil;
    [onDidLoadObjectsForPage release];
    onDidLoadObjectsForPage = nil;
    [onDidFailWithError release];
    onDidFailWithError = nil;
    [pageLoaders release];
    pageLoaders = nil;

    [super dealloc];
}

- (RKObjectMapping *)paginationMapping {
    return [mappingProvider paginationMapping];
}

- (RKURL *)URL {
    return [patternURL URLByInterpolatingResourcePathWithObject:self];
}

- (BOOL)hasPageCount {
    return pageCount != NSUIntegerMax;
}

- (BOOL)hasObjectCount {
    return objectCount != NSUIntegerMax;
}

- (NSUInteger)pageCount {
    //NSAssert([self hasPageCount], @"Page count not available.");
    return pageCount;
}

- (BOOL)hasPage:(NSUInteger)page{
    
    if(![self hasPageCount])
        return NO;
    
    return page < self.pageCount;

}

- (BOOL)hasLoadedPage:(NSUInteger)page{
    NSAssert(page > 0, @"Pages start at 1");
    
    if([self.pageLoaders count] >= page)
        return [[self loaderForPage:page] isLoaded];
    
    return NO;
}

- (NSUInteger)numberOfPagesLoaded{
    
    __block NSUInteger num = 0;
    
    [self.pageLoaders enumerateObjectsUsingBlock:^(RKObjectLoader *obj, NSUInteger idx, BOOL *stop) {
        
        if([obj isLoaded])
            num++;
        
    }];
    
    return num;
    
}

- (RKObjectLoader*)loaderForPage:(NSUInteger)page{
    NSAssert(page > 0, @"Pages start at 1");
    
    if([self.pageLoaders count] >= page)
        return [self.pageLoaders objectAtIndex:page-1];
    
    return nil;
}

- (NSUInteger)pageForLoader:(RKObjectLoader*)loader{
    
    NSUInteger page = [self.pageLoaders indexOfObject:loader];
    
    if(page == NSNotFound)
        return page;
    
    return page + 1;
}

#pragma mark - RKObjectLoaderDelegate methods


- (void)objectLoader:(RKObjectLoader *)objectLoader didLoadObjects:(NSArray *)objects {
        
    //RKLogInfo(@"Loaded objects: %@", objects);
        
    NSUInteger theCurrentPage = [self pageForLoader:objectLoader];
    
    [self.delegate paginator:self didLoadObjects:objects forPage:theCurrentPage];
    
    if (self.onDidLoadObjectsForPage) {
        self.onDidLoadObjectsForPage(objects, theCurrentPage);
    }
}

- (void)objectLoaderDidFinishLoading:(RKObjectLoader *)objectLoader{
    
    BOOL hasCount = [self hasPageCount];
    
    NSUInteger theNumberOfPagesLoaded = [self numberOfPagesLoaded];
    NSUInteger thePageCount =  self.pageCount;
            
    if (hasCount && theNumberOfPagesLoaded == 1) {
        if ([self.delegate respondsToSelector:@selector(paginatorDidLoadFirstPage:)]) {
            [self.delegate paginatorDidLoadFirstPage:self];
                        
        }
        
        [self loadAllPages];

    }
    
    if (hasCount && theNumberOfPagesLoaded == thePageCount) {
        if ([self.delegate respondsToSelector:@selector(paginatorDidLoadLastPage:)]) {
            [self.delegate paginatorDidLoadLastPage:self];
        }
    }

}

- (void)objectLoader:(RKObjectLoader *)objectLoader didFailWithError:(NSError *)error {
    RKLogError(@"Paginator error %@", error);
    [self.delegate paginator:self didFailWithError:error objectLoader:objectLoader];
    if (self.onDidFailWithError) {
        self.onDidFailWithError(error, objectLoader);
    }
    
    [self cancel];
}

- (void)objectLoader:(RKObjectLoader *)loader willMapData:(inout id *)mappableData {
    NSError *error = nil;
    RKObjectMappingOperation *mappingOperation = [RKObjectMappingOperation mappingOperationFromObject:*mappableData toObject:self withMapping:[self paginationMapping]];
    BOOL success = [mappingOperation performMapping:&error];
    if (!success) {
      pageCount = 0;
      RKLogError(@"Paginator didn't map info to compute page count. Assuming no pages.");
    } else if (self.perPage && [self hasObjectCount]) {
      //float objectCountFloat = self.objectCount;
      //pageCount = ceilf(objectCountFloat / self.perPage);
      RKLogInfo(@"Paginator objectCount: %ld pageCount: %ld", (long) self.objectCount, (long) self.pageCount);
    } else {
      NSAssert(NO, @"Paginator perPage set is 0.");
      RKLogError(@"Paginator perPage set is 0.");
    }
}

#pragma mark - Action methods

- (void)loadAllPages{
    
    if(![self hasPageCount]){
                
        [self loadPage:1];

    }else{

        int theCurrentPage = [[self pageLoaders] count] + 1;
        
        for (int i = theCurrentPage; i <= self.pageCount; i++) {
            
            [self loadPage:i];
            
        }
    }
}


- (void)loadPage:(NSUInteger)pageNumber {
    NSAssert(self.mappingProvider, @"Cannot perform a load with a nil mappingProvider.");
    currentPage = pageNumber;

    RKObjectLoader* nextLoader = nil;
    
    if (self.objectStore) {
        nextLoader = [[[RKManagedObjectLoader alloc] initWithURL:self.URL mappingProvider:self.mappingProvider objectStore:self.objectStore] autorelease];
    } else {
        nextLoader = [[[RKObjectLoader alloc] initWithURL:self.URL mappingProvider:self.mappingProvider] autorelease];
    }

    if ([self.configurationDelegate respondsToSelector:@selector(configureObjectLoader:)]) {
        [self.configurationDelegate configureObjectLoader:nextLoader];
    }
    nextLoader.method = RKRequestMethodGET;
    nextLoader.delegate = self;

    if ([self.delegate respondsToSelector:@selector(paginator:willLoadPage:objectLoader:)]) {
        [self.delegate paginator:self willLoadPage:pageNumber objectLoader:nextLoader];
    }

    [nextLoader send];
    
    [self.pageLoaders addObject:nextLoader];
}


- (void)cancel{
    
    [self.pageLoaders enumerateObjectsUsingBlock:^(RKObjectLoader* objectLoader, NSUInteger idx, BOOL *stop) {
        
        objectLoader.delegate = nil;
        [objectLoader cancel];
        
    }];
}


@end
