//
//  ABI27_0_0EXMediaLibrary.m
//  Exponent
//
//  Created by Tomasz Sapeta on 29.01.2018.
//  Copyright © 2018 650 Industries. All rights reserved.
//

#import "ABI27_0_0EXMediaLibrary.h"
#import "ABI27_0_0EXFileSystem.h"
#import "ABI27_0_0EXPermissions.h"
#import "ABI27_0_0EXScopedModuleRegistry.h"
#import "ABI27_0_0EXCameraRollRequester.h"

#import <Photos/Photos.h>
#import <ReactABI27_0_0/ABI27_0_0RCTUIManager.h>
#import <MobileCoreServices/MobileCoreServices.h>

NSString *const ABI27_0_0EXAssetMediaTypeAudio = @"audio";
NSString *const ABI27_0_0EXAssetMediaTypePhoto = @"photo";
NSString *const ABI27_0_0EXAssetMediaTypeVideo = @"video";
NSString *const ABI27_0_0EXAssetMediaTypeUnknown = @"unknown";
NSString *const ABI27_0_0EXAssetMediaTypeAll = @"all";

@interface ABI27_0_0EXMediaLibrary ()

@property (nonatomic, weak) id<ABI27_0_0EXPermissionsScopedModuleDelegate> kernelPermissionsServiceDelegate;

@end

@implementation ABI27_0_0EXMediaLibrary

@synthesize bridge = _bridge;

ABI27_0_0EX_EXPORT_SCOPED_MODULE(ExponentMediaLibrary, PermissionsManager);

- (instancetype)initWithExperienceId:(NSString *)experienceId kernelServiceDelegate:(id<ABI27_0_0EXPermissionsScopedModuleDelegate>)kernelServiceInstance params:(NSDictionary *)params
{
  if (self = [super initWithExperienceId:experienceId kernelServiceDelegate:kernelServiceInstance params:params]) {
    _kernelPermissionsServiceDelegate = kernelServiceInstance;
  }
  return self;
}

- (dispatch_queue_t)methodQueue
{
  return dispatch_queue_create("host.exp.exponent.MediaLibrary", DISPATCH_QUEUE_SERIAL);
}

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

- (NSDictionary *)constantsToExport
{
  return @{
           @"MediaType": @{
               @"audio": ABI27_0_0EXAssetMediaTypeAudio,
               @"photo": ABI27_0_0EXAssetMediaTypePhoto,
               @"video": ABI27_0_0EXAssetMediaTypeVideo,
               @"unknown": ABI27_0_0EXAssetMediaTypeUnknown,
               @"all": ABI27_0_0EXAssetMediaTypeAll,
               },
           @"SortBy": @{
               @"default": @"default",
               @"id": @"id",
               @"creationTime": @"creationTime",
               @"modificationTime": @"modificationTime",
               @"mediaType": @"mediaType",
               @"width": @"width",
               @"height": @"height",
               @"duration": @"duration",
               }
           };
}

ABI27_0_0RCT_REMAP_METHOD(createAssetAsync,
                 createAssetFromLocalUri:(nonnull NSString *)localUri
                 resolve:(ABI27_0_0RCTPromiseResolveBlock)resolve
                 reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  PHAssetMediaType assetType = [ABI27_0_0EXMediaLibrary _assetTypeForUri:localUri];
  
  if (assetType == PHAssetMediaTypeUnknown || assetType == PHAssetMediaTypeAudio) {
    reject(@"E_UNSUPPORTED_ASSET", @"This file type is not supported yet", nil);
    return;
  }
  
  NSURL *assetUrl = [NSURL URLWithString:localUri];
  
  if (assetUrl == nil) {
    reject(@"E_INVALID_URI", @"Provided localUri is not a valid URI", nil);
    return;
  }
  if (!([_bridge.scopedModules.fileSystem permissionsForURI:assetUrl] & ABI27_0_0EXFileSystemPermissionRead)) {
    reject(@"E_FILESYSTEM_PERMISSIONS", [NSString stringWithFormat:@"File '%@' isn't readable.", assetUrl], nil);
    return;
  }
  
  __block PHObjectPlaceholder *assetPlaceholder;
  
  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    PHAssetChangeRequest *changeRequest = assetType == PHAssetMediaTypeVideo
                                        ? [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:assetUrl]
                                        : [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:assetUrl];
    
    assetPlaceholder = changeRequest.placeholderForCreatedAsset;
    
  } completionHandler:^(BOOL success, NSError *error) {
    if (success) {
      PHAsset *asset = [ABI27_0_0EXMediaLibrary _getAssetById:assetPlaceholder.localIdentifier];
      resolve([ABI27_0_0EXMediaLibrary _exportAsset:asset]);
    } else {
      reject(@"E_ASSET_SAVE_FAILED", @"Asset couldn't be saved to photo library", error);
    }
  }];
}

ABI27_0_0RCT_REMAP_METHOD(addAssetsToAlbumAsync,
                 addAssets:(NSArray<NSString *> *)assetIds
                 toAlbum:(nonnull NSString *)albumId
                 resolve:(ABI27_0_0RCTPromiseResolveBlock)resolve
                 reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  [ABI27_0_0EXMediaLibrary _addAssets:assetIds toAlbum:albumId withCallback:^(BOOL success, NSError *error) {
    if (error) {
      reject(@"E_ADD_TO_ALBUM_FAILED", @"Couldn\'t add assets to album", error);
    } else {
      resolve(@(success));
    }
  }];
}

ABI27_0_0RCT_REMAP_METHOD(removeAssetsFromAlbumAsync,
                 removeAssets:(NSArray<NSString *> *)assetIds
                 fromAlbum:(nonnull NSString *)albumId
                 resolve:(ABI27_0_0RCTPromiseResolveBlock)resolve
                 reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    PHAssetCollection *collection = [ABI27_0_0EXMediaLibrary _getAlbumById:albumId];
    PHFetchResult *assets = [ABI27_0_0EXMediaLibrary _getAssetsByIds:assetIds];
    
    PHFetchResult *collectionAssets = [PHAsset fetchAssetsInAssetCollection:collection options:nil];
    PHAssetCollectionChangeRequest *albumChangeRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:collection assets:collectionAssets];
    
    [albumChangeRequest removeAssets:assets];
    
  } completionHandler:^(BOOL success, NSError *error) {
    if (error) {
      reject(@"E_REMOVE_FROM_ALBUM_FAILED", @"Couldn\'t remove assets from album", error);
    } else {
      resolve(@(success));
    }
  }];
}

ABI27_0_0RCT_REMAP_METHOD(deleteAssetsAsync,
                 deleteAssets:(NSArray<NSString *>*)assetIds
                 resolve:(ABI27_0_0RCTPromiseResolveBlock)resolve
                 reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    PHFetchResult *fetched = [PHAsset fetchAssetsWithLocalIdentifiers:assetIds options:nil];
    [PHAssetChangeRequest deleteAssets:fetched];
    
  } completionHandler:^(BOOL success, NSError *error) {
    if (success == YES) {
      resolve(@(success));
    } else {
      reject(@"E_ASSET_REMOVE_FAILED", @"Couldn't remove assets", error);
    }
  }];
}

ABI27_0_0RCT_EXPORT_METHOD(getAlbumsAsync:(ABI27_0_0RCTPromiseResolveBlock)resolve
                  reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  PHFetchOptions *options = [PHFetchOptions new];
  options.includeHiddenAssets = NO;
  options.includeAllBurstAssets = NO;
  
  PHFetchResult *fetchResult = [PHCollectionList fetchTopLevelUserCollectionsWithOptions:options];
  NSArray<NSDictionary *> *albums = [ABI27_0_0EXMediaLibrary _exportCollections:fetchResult];
  
  resolve(albums);
}

ABI27_0_0RCT_REMAP_METHOD(getMomentsAsync,
                 getMoments:(ABI27_0_0RCTPromiseResolveBlock)resolve
                 reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  PHFetchOptions *options = [PHFetchOptions new];
  options.includeHiddenAssets = NO;
  options.includeAllBurstAssets = NO;
  
  PHFetchResult *fetchResult = [PHAssetCollection fetchMomentsWithOptions:options];
  NSArray<NSDictionary *> *albums = [ABI27_0_0EXMediaLibrary _exportCollections:fetchResult];
  
  resolve(albums);
}

ABI27_0_0RCT_REMAP_METHOD(getAlbumAsync,
                 getAlbumWithTitle:(nonnull NSString *)title
                 resolve:(ABI27_0_0RCTPromiseResolveBlock)resolve
                 reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  PHAssetCollection *collection = [ABI27_0_0EXMediaLibrary _getAlbumWithTitle:title];
  resolve([ABI27_0_0EXMediaLibrary _exportCollection:collection]);
}

ABI27_0_0RCT_REMAP_METHOD(createAlbumAsync,
                 createAlbumWithTitle:(nonnull NSString *)title
                 withAssetId:(NSString *)assetId
                 resolve:(ABI27_0_0RCTPromiseResolveBlock)resolve
                 reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  [ABI27_0_0EXMediaLibrary _createAlbumWithTitle:title completion:^(PHAssetCollection *collection, NSError *error) {
    if (collection) {
      if (assetId) {
        [ABI27_0_0EXMediaLibrary _addAssets:@[assetId] toAlbum:collection.localIdentifier withCallback:^(BOOL success, NSError *error) {
          if (success) {
            resolve([ABI27_0_0EXMediaLibrary _exportCollection:collection]);
          } else {
            reject(@"E_ALBUM_CANT_ADD_ASSET", @"Unable to add asset to the new album", error);
          }
        }];
      } else {
        resolve([ABI27_0_0EXMediaLibrary _exportCollection:collection]);
      }
    } else {
      reject(@"E_ALBUM_CREATE_FAILED", @"Could not create album", error);
    }
  }];
}

ABI27_0_0RCT_REMAP_METHOD(getAssetInfoAsync,
                 getAssetInfo:(nonnull NSString *)assetId
                 resolve:(ABI27_0_0RCTPromiseResolveBlock)resolve
                 reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  PHAsset *asset = [ABI27_0_0EXMediaLibrary _getAssetById:assetId];
  
  if (asset) {
    NSMutableDictionary *result = [ABI27_0_0EXMediaLibrary _exportAssetInfo:asset];
    PHContentEditingInputRequestOptions *options = [PHContentEditingInputRequestOptions new];
    options.networkAccessAllowed = YES;
    
    [asset requestContentEditingInputWithOptions:options completionHandler:^(PHContentEditingInput * _Nullable contentEditingInput, NSDictionary * _Nonnull info) {
      result[@"localUri"] = [contentEditingInput.fullSizeImageURL absoluteString];
      result[@"orientation"] = @(contentEditingInput.fullSizeImageOrientation);
      
      if (asset.mediaType == PHAssetMediaTypeImage) {
        CIImage *ciImage = [CIImage imageWithContentsOfURL:contentEditingInput.fullSizeImageURL];
        result[@"exif"] = ciImage.properties;
      }
      resolve(result);
    }];
  } else {
    resolve(nil);
  }
}

ABI27_0_0RCT_REMAP_METHOD(getAssetsAsync,
                 getAssetsWithOptions:(NSDictionary *)options
                 resolve:(ABI27_0_0RCTPromiseResolveBlock)resolve
                 reject:(ABI27_0_0RCTPromiseRejectBlock)reject)
{
  if (![self _checkPermissions:reject]) {
    return;
  }
  
  PHFetchOptions *fetchOptions = [PHFetchOptions new];
  NSMutableArray<NSPredicate *> *predicates = [NSMutableArray new];
  NSMutableDictionary *response = [NSMutableDictionary new];
  NSMutableArray<NSDictionary *> *assets = [NSMutableArray new];
  
  // options
  NSString *after = options[@"after"];
  NSInteger first = [options[@"first"] integerValue] ?: 20;
  NSArray<NSString *> *mediaType = options[@"mediaType"];
  NSArray *sortBy = options[@"sortBy"];
  NSString *albumId = options[@"album"];
  
  PHAssetCollection *collection;
  PHAsset *cursor;
  
  if (after) {
    cursor = [ABI27_0_0EXMediaLibrary _getAssetById:after];
    
    if (!cursor) {
      reject(@"E_CURSOR_NOT_FOUND", @"Couldn't find cursor", nil);
      return;
    }
  }
  
  if (albumId) {
    collection = [ABI27_0_0EXMediaLibrary _getAlbumById:albumId];
    
    if (!collection) {
      reject(@"E_ALBUM_NOT_FOUND", @"Couldn't find album", nil);
      return;
    }
  }
  
  if (mediaType && [mediaType count] > 0) {
    NSMutableArray<NSNumber *> *assetTypes = [ABI27_0_0EXMediaLibrary _convertMediaTypes:mediaType];
    
    if ([assetTypes count] > 0) {
      NSPredicate *predicate = [NSPredicate predicateWithFormat:@"mediaType IN %@", assetTypes];
      [predicates addObject:predicate];
    }
  }
  
  if (sortBy && sortBy.count > 0) {
    fetchOptions.sortDescriptors = [ABI27_0_0EXMediaLibrary _prepareSortDescriptors:sortBy];
  }
  
  if (predicates.count > 0) {
    NSCompoundPredicate *compoundPredicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
    fetchOptions.predicate = compoundPredicate;
  }
  
  fetchOptions.includeAssetSourceTypes = PHAssetSourceTypeUserLibrary;
  fetchOptions.includeAllBurstAssets = NO;
  fetchOptions.includeHiddenAssets = NO;
  
  PHFetchResult *fetchResult = collection
    ? [PHAsset fetchAssetsInAssetCollection:collection options:fetchOptions]
    : [PHAsset fetchAssetsWithOptions:fetchOptions];
  
  NSInteger cursorIndex = cursor ? [fetchResult indexOfObject:cursor] : NSNotFound;
  NSInteger totalCount = fetchResult.count;
  BOOL hasNextPage;
  
  // If we don't use any sort descriptors, the assets are sorted just like in Photos app.
  // That means they are in the insertion order, so the most recent assets are at the end.
  // Therefore, we need to reverse indexes to place them at the beginning.
  if (fetchOptions.sortDescriptors.count == 0) {
    NSInteger startIndex = MAX(cursorIndex == NSNotFound ? totalCount - 1 : cursorIndex - 1, -1);
    NSInteger endIndex = MAX(startIndex - first + 1, 0);
    
    for (NSInteger i = startIndex; i >= endIndex; i--) {
      PHAsset *asset = [fetchResult objectAtIndex:i];
      [assets addObject:[ABI27_0_0EXMediaLibrary _exportAsset:asset]];
    }
    
    hasNextPage = endIndex > 0;
  } else {
    NSInteger startIndex = cursorIndex == NSNotFound ? 0 : cursorIndex + 1;
    NSInteger endIndex = MIN(startIndex + first, totalCount);
    
    for (NSInteger i = startIndex; i < endIndex; i++) {
      PHAsset *asset = [fetchResult objectAtIndex:i];
      [assets addObject:[ABI27_0_0EXMediaLibrary _exportAsset:asset]];
    }
    hasNextPage = endIndex < totalCount - 1;
  }
  
  NSDictionary *lastAsset = [assets lastObject];
  
  response[@"assets"] = assets;
  response[@"endCursor"] = lastAsset ? lastAsset[@"id"] : after;
  response[@"hasNextPage"] = @(hasNextPage);
  response[@"totalCount"] = @(totalCount);
  
  resolve(response);
}


# pragma mark - Internal methods


+ (PHFetchResult *)_getAssetsByIds:(NSArray<NSString *> *)assetIds
{
  PHFetchOptions *options = [PHFetchOptions new];
  options.includeHiddenAssets = YES;
  options.includeAllBurstAssets = YES;
  options.fetchLimit = assetIds.count;
  return [PHAsset fetchAssetsWithLocalIdentifiers:assetIds options:options];
}

+ (PHAsset *)_getAssetById:(NSString *)assetId
{
  if (assetId) {
    return [ABI27_0_0EXMediaLibrary _getAssetsByIds:@[assetId]].firstObject;
  }
  return nil;
}

+ (PHAssetCollection *)_getAlbumWithTitle:(nonnull NSString *)title
{
  PHFetchOptions *options = [PHFetchOptions new];
  options.predicate = [NSPredicate predicateWithFormat:@"title == %@", title];
  options.fetchLimit = 1;
  
  PHFetchResult *fetchResult = [PHAssetCollection
                                fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                subtype:PHAssetCollectionSubtypeAlbumRegular
                                options:options];

  return fetchResult.firstObject;
}

+ (PHAssetCollection *)_getAlbumById:(nonnull NSString *)albumId
{
  PHFetchOptions *options = [PHFetchOptions new];
  options.fetchLimit = 1;
  return [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[albumId] options:options].firstObject;
}

+ (void)_ensureAlbumWithTitle:(nonnull NSString *)title completion:(void(^)(PHAssetCollection *collection, NSError *error))completion
{
  PHAssetCollection *collection = [ABI27_0_0EXMediaLibrary _getAlbumWithTitle:title];
  
  if (collection) {
    completion(collection, nil);
    return;
  }
  
  [ABI27_0_0EXMediaLibrary _createAlbumWithTitle:title completion:completion];
}

+ (void)_createAlbumWithTitle:(nonnull NSString *)title completion:(void(^)(PHAssetCollection *collection, NSError *error))completion
{
  __block PHObjectPlaceholder *collectionPlaceholder;
  
  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    PHAssetCollectionChangeRequest *changeRequest = [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:title];
    collectionPlaceholder = changeRequest.placeholderForCreatedAssetCollection;
    
  } completionHandler:^(BOOL success, NSError *error) {
    if (success) {
      PHFetchResult *fetchResult = [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[collectionPlaceholder.localIdentifier] options:nil];
      completion(fetchResult.firstObject, nil);
    } else {
      completion(nil, error);
    }
  }];
}

+ (void)_addAssets:(NSArray<NSString *> *)assetIds toAlbum:(nonnull NSString *)albumId withCallback:(void(^)(BOOL success, NSError *error))callback
{
  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    PHAssetCollection *collection = [ABI27_0_0EXMediaLibrary _getAlbumById:albumId];
    PHFetchResult *assets = [ABI27_0_0EXMediaLibrary _getAssetsByIds:assetIds];
    
    PHFetchResult *collectionAssets = [PHAsset fetchAssetsInAssetCollection:collection options:nil];
    PHAssetCollectionChangeRequest *albumChangeRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:collection assets:collectionAssets];
    
    [albumChangeRequest addAssets:assets];
  } completionHandler:callback];
}

+ (NSDictionary *)_exportAsset:(PHAsset *)asset
{
  if (asset) {
    NSString *fileName = [asset valueForKey:@"filename"];
    NSString *assetExtension = [fileName pathExtension];
    
    return @{
             @"id": asset.localIdentifier,
             @"filename": fileName,
             @"uri": [ABI27_0_0EXMediaLibrary _assetUriForLocalId:asset.localIdentifier andExtension:assetExtension],
             @"mediaType": [ABI27_0_0EXMediaLibrary _stringifyMediaType:asset.mediaType],
             @"mediaSubtypes": [ABI27_0_0EXMediaLibrary _stringifyMediaSubtypes:asset.mediaSubtypes],
             @"width": @(asset.pixelWidth),
             @"height": @(asset.pixelHeight),
             @"creationTime": [ABI27_0_0EXMediaLibrary _exportDate:asset.creationDate],
             @"modificationTime": [ABI27_0_0EXMediaLibrary _exportDate:asset.modificationDate],
             @"duration": @(asset.duration),
             };
  }
  return nil;
}

+ (NSMutableDictionary *)_exportAssetInfo:(PHAsset *)asset
{
  NSMutableDictionary *assetDict = [[ABI27_0_0EXMediaLibrary _exportAsset:asset] mutableCopy];
  
  if (assetDict) {
    assetDict[@"location"] = [ABI27_0_0EXMediaLibrary _exportLocation:asset.location];
    assetDict[@"isFavorite"] = @(asset.isFavorite);
    assetDict[@"isHidden"] = @(asset.isHidden);
    return assetDict;
  }
  return nil;
}

+ (NSNumber *)_exportDate:(NSDate *)date
{
  if (date) {
    NSTimeInterval interval = date.timeIntervalSince1970;
    NSUInteger intervalMs = interval * 1000;
    return [NSNumber numberWithUnsignedInteger:intervalMs];
  }
  return (id)[NSNull null];
}

+ (NSDictionary *)_exportCollection:(PHAssetCollection *)collection
{
  if (collection) {
    return @{
             @"id": [ABI27_0_0EXMediaLibrary _assetIdFromLocalId:collection.localIdentifier],
             @"title": collection.localizedTitle ?: [NSNull null],
             @"type": [ABI27_0_0EXMediaLibrary _stringifyAlbumType:collection.assetCollectionType],
             @"assetCount": [ABI27_0_0EXMediaLibrary _assetCountOfCollection:collection],
             @"startTime": [ABI27_0_0EXMediaLibrary _exportDate:collection.startDate],
             @"endTime": [ABI27_0_0EXMediaLibrary _exportDate:collection.endDate],
             @"approximateLocation": [ABI27_0_0EXMediaLibrary _exportLocation:collection.approximateLocation],
             @"locationNames": collection.localizedLocationNames,
             };
  }
  return nil;
}

+ (NSArray *)_exportCollections:(PHFetchResult *)collections
{
  NSMutableArray<NSDictionary *> *albums = [NSMutableArray new];
  
  for (PHAssetCollection *collection in collections) {
    [albums addObject:[ABI27_0_0EXMediaLibrary _exportCollection:collection]];
  }
  return [albums copy];
}

+ (nullable NSDictionary *)_exportLocation:(CLLocation *)location
{
  if (location) {
    return @{
             @"latitude": @(location.coordinate.latitude),
             @"longitude": @(location.coordinate.longitude),
             };
  }
  return (id)[NSNull null];
}

+ (NSString *)_assetIdFromLocalId:(nonnull NSString *)localId
{
  // PHAsset's localIdentifier looks like `8B51C35E-E1F3-4D18-BF90-22CC905737E9/L0/001`
  // however `/L0/001` doesn't take part in URL to the asset, so we need to strip it out.
  return [localId stringByReplacingOccurrencesOfString:@"/.*" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, localId.length)];
}

+ (NSString *)_assetUriForLocalId:(nonnull NSString *)localId andExtension:(nonnull NSString *)extension
{
  NSString *assetId = [ABI27_0_0EXMediaLibrary _assetIdFromLocalId:localId];
  NSString *uppercasedExtension = [extension uppercaseString];
  
  return [NSString stringWithFormat:@"assets-library://asset/asset.%@?id=%@&ext=%@", uppercasedExtension, assetId, uppercasedExtension];
}

+ (PHAssetMediaType)_assetTypeForUri:(nonnull NSString *)localUri
{
  CFStringRef fileExtension = (__bridge CFStringRef)[localUri pathExtension];
  CFStringRef fileUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, fileExtension, NULL);
  
  if (UTTypeConformsTo(fileUTI, kUTTypeImage)) {
    return PHAssetMediaTypeImage;
  }
  if (UTTypeConformsTo(fileUTI, kUTTypeMovie)) {
    return PHAssetMediaTypeVideo;
  }
  if (UTTypeConformsTo(fileUTI, kUTTypeAudio)) {
    return PHAssetMediaTypeAudio;
  }
  return PHAssetMediaTypeUnknown;
}

+ (NSString *)_stringifyMediaType:(PHAssetMediaType)mediaType
{
  switch (mediaType) {
    case PHAssetMediaTypeAudio:
      return ABI27_0_0EXAssetMediaTypeAudio;
    case PHAssetMediaTypeImage:
      return ABI27_0_0EXAssetMediaTypePhoto;
    case PHAssetMediaTypeVideo:
      return ABI27_0_0EXAssetMediaTypeVideo;
    default:
      return ABI27_0_0EXAssetMediaTypeUnknown;
  }
}

+ (PHAssetMediaType)_convertMediaType:(NSString *)mediaType
{
  if ([mediaType isEqualToString:ABI27_0_0EXAssetMediaTypeAudio]) {
    return PHAssetMediaTypeAudio;
  }
  if ([mediaType isEqualToString:ABI27_0_0EXAssetMediaTypePhoto]) {
    return PHAssetMediaTypeImage;
  }
  if ([mediaType isEqualToString:ABI27_0_0EXAssetMediaTypeVideo]) {
    return PHAssetMediaTypeVideo;
  }
  return PHAssetMediaTypeUnknown;
}

+ (NSMutableArray<NSNumber *> *)_convertMediaTypes:(NSArray<NSString *> *)mediaTypes
{
  __block NSMutableArray<NSNumber *> *assetTypes = [NSMutableArray new];
  
  [mediaTypes enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
    if ([obj isEqualToString:ABI27_0_0EXAssetMediaTypeAll]) {
      *stop = YES;
      assetTypes = nil;
      return;
    }
    PHAssetMediaType assetType = [ABI27_0_0EXMediaLibrary _convertMediaType:obj];
    [assetTypes addObject:@(assetType)];
  }];
  
  return assetTypes;
}

+ (NSString *)_convertSortByKey:(NSString *)key
{
  if ([key isEqualToString:@"default"]) {
    return nil;
  }
  
  NSDictionary *conversionDict = @{
                                   @"id": @"localIdentifier",
                                   @"creationTime": @"creationDate",
                                   @"modificationTime": @"modificationDate",
                                   @"mediaType": @"mediaType",
                                   @"width": @"pixelWidth",
                                   @"height": @"pixelHeight",
                                   @"duration": @"duration",
                                   };
  NSString *value = [conversionDict valueForKey:key];
  
  if (value == nil) {
    NSString *reason = [NSString stringWithFormat:@"SortBy key \"%@\" is not supported!", key];
    @throw [NSException exceptionWithName:@"ABI27_0_0EXMediaLibrary.UNSUPPORTED_SORTBY_KEY" reason:reason userInfo:nil];
  }
  return value;
}

+ (NSArray<NSString *> *)_stringifyMediaSubtypes:(PHAssetMediaSubtype)mediaSubtypes
{
  NSMutableArray *subtypes = [NSMutableArray new];
  NSMutableDictionary<NSString *, NSNumber *> *subtypesDict = [@{
                                                               @"hdr": @(PHAssetMediaSubtypePhotoHDR),
                                                               @"panorama": @(PHAssetMediaSubtypePhotoPanorama),
                                                               @"stream": @(PHAssetMediaSubtypeVideoStreamed),
                                                               @"timelapse": @(PHAssetMediaSubtypeVideoTimelapse),
                                                               @"screenshot": @(PHAssetMediaSubtypePhotoScreenshot),
                                                               @"highFrameRate": @(PHAssetMediaSubtypeVideoHighFrameRate)
                                                               } mutableCopy];
  
  if (@available(iOS 9.1, *)) {
    subtypesDict[@"livePhoto"] = @(PHAssetMediaSubtypePhotoLive);
  }
  if (@available(iOS 10.2, *)) {
    subtypesDict[@"depthEffect"] = @(PHAssetMediaSubtypePhotoDepthEffect);
  }
  
  for (NSString *subtype in subtypesDict) {
    if (mediaSubtypes & [subtypesDict[subtype] unsignedIntegerValue]) {
      [subtypes addObject:subtype];
    }
  }
  return subtypes;
}

+ (NSString *)_stringifyAlbumType:(PHAssetCollectionType)assetCollectionType
{
  switch (assetCollectionType) {
    case PHAssetCollectionTypeAlbum:
      return @"album";
    case PHAssetCollectionTypeMoment:
      return @"moment";
    case PHAssetCollectionTypeSmartAlbum:
      return @"smartAlbum";
  }
}

+ (NSNumber *)_assetCountOfCollection:(PHAssetCollection *)collection
{
  if (collection.estimatedAssetCount == NSNotFound) {
    PHFetchOptions *options = [PHFetchOptions new];
    options.includeHiddenAssets = NO;
    options.includeAllBurstAssets = NO;
    
    return @([PHAsset fetchAssetsInAssetCollection:collection options:options].count);
  }
  return @(collection.estimatedAssetCount);
}

+ (NSSortDescriptor *)_sortDescriptorFrom:(id)config
{
  if ([config isKindOfClass:[NSString class]]) {
    NSString *key = [ABI27_0_0EXMediaLibrary _convertSortByKey:config];
    
    if (key) {
      return [NSSortDescriptor sortDescriptorWithKey:key ascending:NO];
    }
  }
  if ([config isKindOfClass:[NSArray class]]) {
    NSArray *sortArray = (NSArray *)config;
    NSString *key = [ABI27_0_0EXMediaLibrary _convertSortByKey:sortArray[0]];
    BOOL ascending = sortArray[1] > 0;
    
    if (key) {
      return [NSSortDescriptor sortDescriptorWithKey:key ascending:ascending];
    }
  }
  return nil;
}

+ (NSArray *)_prepareSortDescriptors:(NSArray *)sortBy
{
  NSMutableArray *sortDescriptors = [NSMutableArray new];
  NSArray *sortByArray = (NSArray *)sortBy;
  
  for (id config in sortByArray) {
    NSSortDescriptor *sortDescriptor = [ABI27_0_0EXMediaLibrary _sortDescriptorFrom:config];
    
    if (sortDescriptor) {
      [sortDescriptors addObject:sortDescriptor];
    }
  }
  return sortDescriptors;
}

- (BOOL)_checkPermissions:(ABI27_0_0RCTPromiseRejectBlock)reject
{
  if ([ABI27_0_0EXPermissions statusForPermissions:[ABI27_0_0EXCameraRollRequester permissions]] != ABI27_0_0EXPermissionStatusGranted ||
      ![_kernelPermissionsServiceDelegate hasGrantedPermission:@"cameraRoll" forExperience:self.experienceId]) {
    reject(@"E_NO_PERMISSIONS", @"CAMERA_ROLL permission is required to do this operation.", nil);
    return NO;
  }
  return YES;
}

@end
