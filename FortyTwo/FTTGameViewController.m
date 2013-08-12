//
//  FTTGameViewController.m
//  FortyTwo
//
//  Created by Forrest Ye on 8/10/13.
//  Copyright (c) 2013 Forrest Ye. All rights reserved.
//

#import "FTTGameViewController.h"

// frameworks
#import <CoreMotion/CoreMotion.h>
#import <AVFoundation/AVFoundation.h>
#import <GameKit/GameKit.h>

// views
#import "FTTUniverseView.h"

// models
#import "FTTUserObject.h"
#import "FTTEnemyObject.h"


@interface FTTGameViewController ()

// motion control
@property (nonatomic) CMMotionManager *motionMannager;
@property (nonatomic) NSOperationQueue *backgroundQueue;

// audio
@property (nonatomic) AVAudioRecorder* recorder;
@property (nonatomic) NSTimer* levelTimer;
@property (nonatomic) CGFloat lowPassResults;

// views
@property (nonatomic) FTTUniverseView *universeView;

// models
@property (nonatomic) FTTUserObject *userObject;
@property (nonatomic) NSMutableArray *enemies;

// game play
@property (nonatomic) BOOL gamePlaying;
@property (nonatomic) BOOL gameStarted;
@property (nonatomic) BOOL gameCenterEnabled;

@property (nonatomic) NSTimeInterval cumulatedCurrentGamePlayTime;
@property (nonatomic) NSTimeInterval resumedTimestamp;

@property (nonatomic) NSTimeInterval cumulatedBombCooldownTime;

@end


@implementation FTTGameViewController


+ (instancetype)sharedInstance {
  static FTTGameViewController *_instance = nil;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _instance = [[self alloc] init];
  });

  return _instance;
}


- (instancetype)init {
  self = [super init];

  if (self) {
    self.wantsFullScreenLayout = YES;

    self.motionMannager = [[CMMotionManager alloc] init];
    self.motionMannager.accelerometerUpdateInterval = 1.0 / 42; // 42 fps baby

    self.backgroundQueue = [[NSOperationQueue alloc] init];
    self.backgroundQueue.maxConcurrentOperationCount = 1;
  }

  return self;
}


- (void)viewDidLoad {
  [super viewDidLoad];

  [self setupPlane];
  [self setupEnemies];
  [self setupShoutDetection];

  self.view.backgroundColor = [UIColor blackColor];
  self.universeView = [[FTTUniverseView alloc] initWithFrame:self.view.bounds];
  self.universeView.userObject = self.userObject;
  self.universeView.enemies = self.enemies;
  [self.view addSubview:self.universeView];

  [self setupGameCenter];
//  [self restartGame];
}


# pragma mark - game control


- (void)restartGame {
  NSParameterAssert(self.motionMannager.accelerometerActive == NO);

  [self.userObject resetPosition];

  [self resetEnemies];

  self.gamePlaying = YES;
  self.gameStarted = YES;

  self.cumulatedCurrentGamePlayTime = 0;
  self.cumulatedBombCooldownTime = 0;
  self.resumedTimestamp = 0;
  [self startReceivingAccelerationData];
}


- (void)youAreDead {
  @synchronized(self) {
    [self.motionMannager stopAccelerometerUpdates];

    if (self.gamePlaying) {
      self.gamePlaying = NO;
      [self reportScore];
      [self showGameOverAlert];
    }
  }
}


- (void)reportScore {
  GKScore *scoreReporter = [[GKScore alloc] initWithCategory:@"com.forresty.FortyTwo.timeLasted"];
  scoreReporter.value = self.cumulatedCurrentGamePlayTime * 100;
  scoreReporter.context = 0;

  [scoreReporter reportScoreWithCompletionHandler:nil];
}


- (void)showGameOverAlert {
  NSString *messageFormat = NSLocalizedString(@"You lasted %.1f seconds.", nil);
  UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"You are dead.", nil)
                                                  message:[NSString stringWithFormat:messageFormat, self.cumulatedCurrentGamePlayTime]
                                                 delegate:self
                                        cancelButtonTitle:NSLocalizedString(@"Retry", nil)
                                        otherButtonTitles: nil];

  [alert show];
}


- (void)pauseGame {
  @synchronized(self) {
    if (self.gamePlaying && self.motionMannager.accelerometerActive) {
      self.resumedTimestamp = 0;

      [self.motionMannager stopAccelerometerUpdates];

      UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Game Paused", nil)
                                                      message:nil
                                                     delegate:self
                                            cancelButtonTitle:NSLocalizedString(@"Resume", nil)
                                            otherButtonTitles:nil];

      [alert show];
    }
  }
}


- (void)resumeGame {
  [self startReceivingAccelerationData];
}


# pragma mark - bomb deployment


- (BOOL)bombDeployed {
  if (self.lowPassResults > 0.5 &&
      self.cumulatedCurrentGamePlayTime - self.cumulatedBombCooldownTime >= FTTBombCooldownTime) {

    self.cumulatedBombCooldownTime = self.cumulatedCurrentGamePlayTime;

    return YES;
  }

  return NO;
}


# pragma mark - shout detection


- (void)setupShoutDetection {
  NSURL *url = [NSURL fileURLWithPath:@"/dev/null"];

  NSDictionary *settings = [NSDictionary dictionaryWithObjectsAndKeys:
                            [NSNumber numberWithFloat: 44100.0], AVSampleRateKey,
                            [NSNumber numberWithInt: kAudioFormatAppleLossless], AVFormatIDKey,
                            [NSNumber numberWithInt: 1], AVNumberOfChannelsKey,
                            [NSNumber numberWithInt: AVAudioQualityMax], AVEncoderAudioQualityKey,
                            nil];

  NSError *error;

  self.recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];

  if (self.recorder) {
    [self.recorder prepareToRecord];
    self.recorder.meteringEnabled = YES;
    [self.recorder record];
    self.levelTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                       target:self
                                                     selector:@selector(levelTimerCallback:)
                                                     userInfo:nil
                                                      repeats:YES];
  }
}


// http://stackoverflow.com/questions/10622721/audio-level-detect
- (void)levelTimerCallback:(NSTimer *)timer {
  [self.recorder updateMeters];

  const double ALPHA = 0.05;

  // I have no idea what this means...
  double peakPowerForChannel = pow(10, (0.05 * [self.recorder peakPowerForChannel:0]));

  // smooth
  self.lowPassResults = ALPHA * peakPowerForChannel + (1.0 - ALPHA) * self.lowPassResults;

//  NSLog(@"%f",(self.lowPassResults * 100.0f));
}


# pragma mark - UI setup


- (void)setupPlane {
  self.userObject = [[FTTUserObject alloc] init];
}


- (void)setupEnemies {
  self.enemies = [NSMutableArray arrayWithCapacity:42];

  for (int i = 0; i < 42; i++) {
    FTTEnemyObject *enemy = [[FTTEnemyObject alloc] init];

    [self.enemies addObject:enemy];
  }
}


- (void)setupGameCenter {
  __weak GKLocalPlayer *localPlayer = [GKLocalPlayer localPlayer];

  localPlayer.authenticateHandler = ^(UIViewController *viewController, NSError *error){
    if (viewController) {
      self.gameCenterEnabled = NO;
//      [self presentViewController:viewController animated:YES completion:nil];
    } else if (localPlayer.isAuthenticated) {
      self.gameCenterEnabled = YES;
      if (self.gameStarted == NO) {
        [self restartGame];
      }
    } else {
      self.gameCenterEnabled = NO;
      if (self.gameStarted == NO) {
        [self restartGame];
      }
    }
  };
}


# pragma mark - position update


- (void)resetEnemies {
  for (int i = 0; i < 42; i++) {
    FTTEnemyObject *enemy = self.enemies[i];

    [enemy resetPosition];
    [enemy resetSpeedWithUserObject:self.userObject];
  }
}


- (CGPoint)updatedPlanePositionWithAccelerometerData:(CMAccelerometerData *)accelerometerData {
  CGFloat speed = 4;

  if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
    speed = 8;
  }

  CGFloat newX = self.userObject.position.x + accelerometerData.acceleration.x * speed;
  CGFloat newY = self.userObject.position.y - accelerometerData.acceleration.y * speed;

  newX = MAX(0, newX);
  newX = MIN(DeviceWidth(), newX);
  newY = MAX(0, newY);
  newY = MIN(DeviceHeight(), newY);
  CGPoint newCenterForPlane = CGPointMake(newX, newY);

  return newCenterForPlane;
}


- (void)startReceivingAccelerationData {
  NSParameterAssert(self.motionMannager.accelerometerActive == NO);

  __weak FTTGameViewController *weakSelf = self;

  [self.motionMannager startAccelerometerUpdatesToQueue:self.backgroundQueue withHandler:^(CMAccelerometerData *accelerometerData, NSError *error) {

    // record time
    if (weakSelf.resumedTimestamp == 0) {
      weakSelf.resumedTimestamp = accelerometerData.timestamp;
    }
    weakSelf.cumulatedCurrentGamePlayTime = accelerometerData.timestamp - weakSelf.resumedTimestamp;

    // bomb
    if (weakSelf.bombDeployed) {
      weakSelf.cumulatedBombCooldownTime = weakSelf.cumulatedCurrentGamePlayTime;
      [weakSelf.universeView deployBomb];
      [weakSelf resetEnemies];
    }

    // move plane
    weakSelf.userObject.position = [weakSelf updatedPlanePositionWithAccelerometerData:accelerometerData];

    // move enemies
    for (int i = 0; i < 42; i++) {
      FTTEnemyObject *enemy = weakSelf.enemies[i];

      [enemy moveTowardsUserObject:weakSelf.userObject];
    }

    // draw universe
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
      weakSelf.universeView.bombCooldownTime = weakSelf.cumulatedCurrentGamePlayTime - weakSelf.cumulatedBombCooldownTime;
      [weakSelf.universeView setNeedsDisplay];
    }];

    // detect collision
    for (int i = 0; i < 42; i++) {
      FTTEnemyObject *enemy = weakSelf.enemies[i];

      if ([enemy hitUserObject:weakSelf.userObject]) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
          [weakSelf youAreDead];
        }];

        break;
      }
    }
  }];
}


# pragma mark - UIAlertViewDelegate


- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  if (self.gamePlaying) {
    [self resumeGame];
  } else {
    [self restartGame];
  }
}


@end
