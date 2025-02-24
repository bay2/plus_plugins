// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FLTSharePlusPlugin.h"
#import "LinkPresentation/LPLinkMetadata.h"
#import "LinkPresentation/LPMetadataProvider.h"

static NSString *const PLATFORM_CHANNEL = @"dev.fluttercommunity.plus/share";

static UIViewController *RootViewController() {
  return [UIApplication sharedApplication].keyWindow.rootViewController;
}

static UIViewController *
TopViewControllerForViewController(UIViewController *viewController) {
  if (viewController.presentedViewController) {
    return TopViewControllerForViewController(
        viewController.presentedViewController);
  }
  if ([viewController isKindOfClass:[UINavigationController class]]) {
    return TopViewControllerForViewController(
        ((UINavigationController *)viewController).visibleViewController);
  }
  return viewController;
}

// We need the companion to avoid ARC deadlock
@interface UIActivityViewSuccessCompanion : NSObject

@property FlutterResult result;
@property NSString *activityType;
@property BOOL completed;

- (id)initWithResult:(FlutterResult)result;

@end

@implementation UIActivityViewSuccessCompanion

- (id)initWithResult:(FlutterResult)result {
  if (self = [super init]) {
    self.result = result;
    self.completed = false;
  }
  return self;
}

// We use dealloc as the share-sheet might disappear (e.g. iCloud photo album
// creation) and could then reappear if the user cancels
- (void)dealloc {
  if (self.completed) {
    self.result(self.activityType);
  } else {
    self.result(@"");
  }
}

@end

@interface UIActivityViewSuccessController : UIActivityViewController

@property UIActivityViewSuccessCompanion *companion;

@end

@implementation UIActivityViewSuccessController
@end

@interface SharePlusData : NSObject <UIActivityItemSource>

@property(readonly, nonatomic, copy) NSString *subject;
@property(readonly, nonatomic, copy) NSString *text;
@property(readonly, nonatomic, copy) NSString *path;
@property(readonly, nonatomic, copy) NSString *mimeType;

- (instancetype)initWithSubject:(NSString *)subject
                           text:(NSString *)text NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFile:(NSString *)path
                    mimeType:(NSString *)mimeType NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFile:(NSString *)path
                    mimeType:(NSString *)mimeType
                     subject:(NSString *)subject NS_DESIGNATED_INITIALIZER;

- (instancetype)init
    __attribute__((unavailable("Use initWithSubject:text: instead")));

@end

@implementation SharePlusData

- (instancetype)init {
  [super doesNotRecognizeSelector:_cmd];
  return nil;
}

- (instancetype)initWithSubject:(NSString *)subject text:(NSString *)text {
  self = [super init];
  if (self) {
    _subject = [subject isKindOfClass:NSNull.class] ? @"" : subject;
    _text = text;
  }
  return self;
}

- (instancetype)initWithFile:(NSString *)path mimeType:(NSString *)mimeType {
  self = [super init];
  if (self) {
    _path = path;
    _mimeType = mimeType;
  }
  return self;
}

- (instancetype)initWithFile:(NSString *)path
                    mimeType:(NSString *)mimeType
                     subject:(NSString *)subject {
  self = [super init];
  if (self) {
    _path = path;
    _mimeType = mimeType;
    _subject = [subject isKindOfClass:NSNull.class] ? @"" : subject;
  }
  return self;
}

- (id)activityViewControllerPlaceholderItem:
    (UIActivityViewController *)activityViewController {
  return @"";
}

- (id)activityViewController:(UIActivityViewController *)activityViewController
         itemForActivityType:(UIActivityType)activityType {
  if (!_path || !_mimeType) {
    return _text;
  }

  if ([_mimeType hasPrefix:@"image/"]) {
    UIImage *image = [UIImage imageWithContentsOfFile:_path];
    return image;
  } else {
    NSURL *url = [NSURL fileURLWithPath:_path];
    return url;
  }
}

- (NSString *)activityViewController:
                  (UIActivityViewController *)activityViewController
              subjectForActivityType:(UIActivityType)activityType {
  return _subject;
}

- (UIImage *)activityViewController:
                 (UIActivityViewController *)activityViewController
      thumbnailImageForActivityType:(UIActivityType)activityType
                      suggestedSize:(CGSize)suggestedSize {
  if (!_path || !_mimeType || ![_mimeType hasPrefix:@"image/"]) {
    return nil;
  }

  UIImage *image = [UIImage imageWithContentsOfFile:_path];
  return [self imageWithImage:image scaledToSize:suggestedSize];
}

- (UIImage *)imageWithImage:(UIImage *)image scaledToSize:(CGSize)newSize {
  UIGraphicsBeginImageContext(newSize);
  [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
  UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return newImage;
}

- (LPLinkMetadata *)activityViewControllerLinkMetadata:
    (UIActivityViewController *)activityViewController
    API_AVAILABLE(macos(10.15), ios(13.0), watchos(6.0)) {
  LPLinkMetadata *metadata = [[LPLinkMetadata alloc] init];

  if ([_subject length] > 0) {
    metadata.title = _subject;
  } else if ([_text length] > 0) {
    metadata.title = _text;
  }

  if (_path) {
    NSString *extesnion = [_path pathExtension];

    unsigned long long rawSize = (
        [[[NSFileManager defaultManager] attributesOfItemAtPath:_path
                                                          error:nil] fileSize]);
    NSString *readableSize = [NSByteCountFormatter
        stringFromByteCount:rawSize
                 countStyle:NSByteCountFormatterCountStyleFile];

    NSString *description = @"";

    if (![extesnion isEqualToString:@""]) {
      description =
          [description stringByAppendingString:[extesnion uppercaseString]];
      description = [description stringByAppendingString:@" • "];
      description = [description stringByAppendingString:readableSize];
    } else {
      description = [description stringByAppendingString:readableSize];
    }

    // https://stackoverflow.com/questions/60563773/ios-13-share-sheet-changing-subtitle-item-description
    metadata.originalURL = [NSURL fileURLWithPath:description];
    if (_mimeType && [_mimeType hasPrefix:@"image/"]) {
      metadata.imageProvider = [[NSItemProvider alloc]
          initWithObject:[UIImage imageWithContentsOfFile:_path]];
    }
  }

  return metadata;
}

@end

@implementation FLTSharePlusPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *shareChannel =
      [FlutterMethodChannel methodChannelWithName:PLATFORM_CHANNEL
                                  binaryMessenger:registrar.messenger];

  [shareChannel
      setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
        BOOL withResult = [call.method hasSuffix:@"WithResult"];
        NSDictionary *arguments = [call arguments];
        NSNumber *originX = arguments[@"originX"];
        NSNumber *originY = arguments[@"originY"];
        NSNumber *originWidth = arguments[@"originWidth"];
        NSNumber *originHeight = arguments[@"originHeight"];

        CGRect originRect = CGRectZero;
        if (originX && originY && originWidth && originHeight) {
          originRect =
              CGRectMake([originX doubleValue], [originY doubleValue],
                         [originWidth doubleValue], [originHeight doubleValue]);
        }

        if ([@"share" isEqualToString:call.method] ||
            [@"shareWithResult" isEqualToString:call.method]) {
          NSString *shareText = arguments[@"text"];
          NSString *shareSubject = arguments[@"subject"];

          if (shareText.length == 0) {
            result([FlutterError errorWithCode:@"error"
                                       message:@"Non-empty text expected"
                                       details:nil]);
            return;
          }

          UIViewController *topViewController =
              TopViewControllerForViewController(RootViewController());
          [self shareText:shareText
                     subject:shareSubject
              withController:topViewController
                    atSource:originRect
                    toResult:withResult ? result : nil];
          if (!withResult)
            result(nil);
        } else if ([@"shareFiles" isEqualToString:call.method] ||
                   [@"shareFilesWithResult" isEqualToString:call.method]) {
          NSArray *paths = arguments[@"paths"];
          NSArray *mimeTypes = arguments[@"mimeTypes"];
          NSString *subject = arguments[@"subject"];
          NSString *text = arguments[@"text"];

          if (paths.count == 0) {
            result([FlutterError errorWithCode:@"error"
                                       message:@"Non-empty paths expected"
                                       details:nil]);
            return;
          }

          for (NSString *path in paths) {
            if (path.length == 0) {
              result([FlutterError errorWithCode:@"error"
                                         message:@"Each path must not be empty"
                                         details:nil]);
              return;
            }
          }

          UIViewController *topViewController =
              TopViewControllerForViewController(RootViewController());
          [self shareFiles:paths
                withMimeType:mimeTypes
                 withSubject:subject
                    withText:text
              withController:topViewController
                    atSource:originRect
                    toResult:withResult ? result : nil];
          if (!withResult)
            result(nil);
        } else {
          result(FlutterMethodNotImplemented);
        }
      }];
}

+ (void)share:(NSArray *)shareItems
       withSubject:(NSString *)subject
    withController:(UIViewController *)controller
          atSource:(CGRect)origin
          toResult:(FlutterResult)result {
  UIActivityViewSuccessController *activityViewController =
      [[UIActivityViewSuccessController alloc] initWithActivityItems:shareItems
                                               applicationActivities:nil];

  // Force subject when sharing a raw url or files
  if (![subject isKindOfClass:[NSNull class]]) {
    [activityViewController setValue:subject forKey:@"subject"];
  }

  activityViewController.popoverPresentationController.sourceView =
      controller.view;
  if (!CGRectIsEmpty(origin)) {
    activityViewController.popoverPresentationController.sourceRect = origin;
  }
  if (result) {
    UIActivityViewSuccessCompanion *companion =
        [[UIActivityViewSuccessCompanion alloc] initWithResult:result];
    activityViewController.companion = companion;
    activityViewController.completionWithItemsHandler =
        ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems,
          NSError *activityError) {
          companion.activityType = activityType;
          companion.completed = completed;
        };
  }
    
    if ( [(NSString*)[UIDevice currentDevice].model hasPrefix:@"iPad"] ) {
        [activityViewController popoverPresentationController].sourceView = UIApplication.sharedApplication.keyWindow;
        [activityViewController popoverPresentationController].sourceRect = CGRectMake( UIApplication.sharedApplication.keyWindow.frame.size.width - 60, 20,40,40);
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller presentViewController:activityViewController
                                 animated:YES
                               completion:nil];
    });
    
  
}

+ (void)shareText:(NSString *)shareText
           subject:(NSString *)subject
    withController:(UIViewController *)controller
          atSource:(CGRect)origin
          toResult:(FlutterResult)result {
  NSObject *data = [[NSURL alloc] initWithString:shareText];
  if (data == nil) {
    data = [[SharePlusData alloc] initWithSubject:subject text:shareText];
  }
  [self share:@[ data ]
         withSubject:subject
      withController:controller
            atSource:origin
            toResult:result];
}

+ (void)shareFiles:(NSArray *)paths
      withMimeType:(NSArray *)mimeTypes
       withSubject:(NSString *)subject
          withText:(NSString *)text
    withController:(UIViewController *)controller
          atSource:(CGRect)origin
          toResult:(FlutterResult)result {
  NSMutableArray *items = [[NSMutableArray alloc] init];

  for (int i = 0; i < [paths count]; i++) {
    NSString *path = paths[i];
    NSString *pathExtension = [path pathExtension];
    NSString *mimeType = mimeTypes[i];
    [items addObject:[[SharePlusData alloc] initWithFile:path
                                                mimeType:mimeType
                                                 subject:subject]];
  }

  [self share:items
         withSubject:subject
      withController:controller
            atSource:origin
            toResult:result];
}

@end
