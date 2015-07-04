/*
 Copyright (C) 2014 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information

 */

#import <GameController/GameController.h>
#import <simd/simd.h>
#import <sys/utsname.h>

#import "AAPLGameViewController.h"
#import "AAPLGameView.h"
#import "AAPLOverlayScene.h"

#define MAX_SPEED 250

@implementation AAPLGameViewController {
    //some node references for manipulation
    SCNNode *_spotLightNode;
    SCNNode *_cameraNode;          //the node that owns the camera
    SCNNode *_vehicleNode;
    SCNNode *_vehicleNode2;
    SCNPhysicsVehicle *_vehicle;
    
    NSMutableArray *_currentWalls;
    NSMutableArray *_nextWalls;
    
    NSMutableArray *_vehiclesPowerArray;
    NSMutableArray *_vehiclesNodesArray;
    NSMutableArray *_vehiclesArray;
    SCNPhysicsVehicle *_vehicle2;
    SCNParticleSystem *_reactor;
    SCNScene *_scene;
    
    //accelerometer
    CMMotionManager *_motionManager;
    UIAccelerationValue	_accelerometer[3];
    CGFloat _orientation;
    
    //reactor's particle birth rate
    CGFloat _reactorDefaultBirthRate;
    
    // steering factor
    CGFloat _vehicleSteering;
    
    int _gear;
}

- (NSString *)deviceName
{
    static NSString *deviceName = nil;
    
    if (deviceName == nil) {
        struct utsname systemInfo;
        uname(&systemInfo);
        
        deviceName = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    }
    return deviceName;
}

- (BOOL)isHighEndDevice
{
    //return YES for iPhone 5s and iPad air, NO otherwise
    if ([[self deviceName] hasPrefix:@"iPad4"]
       || [[self deviceName] hasPrefix:@"iPhone6"]) {
        return YES;
    }
    
    return NO;
}

- (void)setupEnvironment:(SCNScene *)scene
{
    // add an ambient light
    SCNNode *ambientLight = [SCNNode node];
    ambientLight.light = [SCNLight light];
    ambientLight.light.type = SCNLightTypeAmbient;
    ambientLight.light.color = [UIColor colorWithWhite:1 alpha:1.0];
    [[scene rootNode] addChildNode:ambientLight];
    
    //add a key light to the scene
    SCNNode *lightNode = [SCNNode node];
    lightNode.light = [SCNLight light];
    lightNode.light.type = SCNLightTypeSpot;
    if ([self isHighEndDevice])
        lightNode.light.castsShadow = YES;
    lightNode.light.color = [UIColor colorWithWhite:0.8 alpha:1.0];
    lightNode.position = SCNVector3Make(0, 80, 30);
    lightNode.rotation = SCNVector4Make(1,0,0,-M_PI/2.8);
    lightNode.light.spotInnerAngle = 0;
    lightNode.light.spotOuterAngle = 50;
    lightNode.light.shadowColor = [SKColor blackColor];
    lightNode.light.zFar = 500;
    lightNode.light.zNear = 50;
    [[scene rootNode] addChildNode:lightNode];
    
    //keep an ivar for later manipulation
    _spotLightNode = lightNode;
    
    //floor
    SCNNode*floor = [SCNNode node];
    floor.geometry = [SCNFloor floor];
    floor.geometry.firstMaterial.diffuse.contents = @"asphalt.jpg";
    floor.geometry.firstMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(2, 2, 1); //scale the wood texture
    floor.geometry.firstMaterial.locksAmbientWithDiffuse = YES;
    if ([self isHighEndDevice])
        ((SCNFloor*)floor.geometry).reflectionFalloffEnd = 10;
    
    SCNPhysicsBody *staticBody = [SCNPhysicsBody staticBody];
    floor.physicsBody = staticBody;
    [[scene rootNode] addChildNode:floor];
}

- (void)addTrainToScene:(SCNScene *)scene atPosition:(SCNVector3)pos
{
    SCNScene *trainScene = [SCNScene sceneNamed:@"train_flat"];
    
    //physicalize the train with simple boxes
    [trainScene.rootNode.childNodes enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SCNNode *node = (SCNNode *)obj;
        if (node.geometry != nil) {
            node.position = SCNVector3Make(node.position.x + pos.x, node.position.y + pos.y, node.position.z + pos.z);
            
            SCNVector3 min, max;
            [node getBoundingBoxMin:&min max:&max];
            
            SCNPhysicsBody *body = [SCNPhysicsBody dynamicBody];
            SCNBox *boxShape = [SCNBox boxWithWidth:max.x - min.x height:max.y - min.y length:max.z - min.z chamferRadius:0.0];
            body.physicsShape = [SCNPhysicsShape shapeWithGeometry:boxShape options:nil];
            
            node.pivot = SCNMatrix4MakeTranslation(0, -min.y, 0);
            node.physicsBody = body;
            [[scene rootNode] addChildNode:node];
        }
    }];
    
    //add smoke
    SCNNode *smokeHandle = [scene.rootNode childNodeWithName:@"Smoke" recursively:YES];
    [smokeHandle addParticleSystem:[SCNParticleSystem particleSystemNamed:@"smoke" inDirectory:nil]];
    
    //add physics constraints between engine and wagons
    SCNNode *engineCar = [scene.rootNode childNodeWithName:@"EngineCar" recursively:NO];
    SCNNode *wagon1 = [scene.rootNode childNodeWithName:@"Wagon1" recursively:NO];
    SCNNode *wagon2 = [scene.rootNode childNodeWithName:@"Wagon2" recursively:NO];
    
    SCNVector3 min, max;
    [engineCar getBoundingBoxMin:&min max:&max];
    
    SCNVector3 wmin, wmax;
    [wagon1 getBoundingBoxMin:&wmin max:&wmax];
    
    // Tie EngineCar & Wagon1
    SCNPhysicsBallSocketJoint *joint = [SCNPhysicsBallSocketJoint jointWithBodyA:engineCar.physicsBody anchorA:SCNVector3Make(max.x, min.y, 0)
                                                                           bodyB:wagon1.physicsBody anchorB:SCNVector3Make(wmin.x, wmin.y, 0)];
    [scene.physicsWorld addBehavior:joint];
    
    // Wagon1 & Wagon2
    joint = [SCNPhysicsBallSocketJoint jointWithBodyA:wagon1.physicsBody anchorA:SCNVector3Make(wmax.x + 0.1, wmin.y, 0)
                                                bodyB:wagon2.physicsBody anchorB:SCNVector3Make(wmin.x - 0.1, wmin.y, 0)];
    [scene.physicsWorld addBehavior:joint];
}


- (void)addWoodenBlockToScene:(SCNScene *)scene withImageNamed:(NSString *)imageName atPosition:(SCNVector3)position
{
    //create a new node
    SCNNode *block = [SCNNode node];
    
    //place it
    block.position = position;
    
    //attach a box of 5x5x5
    block.geometry = [SCNBox boxWithWidth:5 height:5 length:5 chamferRadius:0];

    //use the specified images named as the texture
    block.geometry.firstMaterial.diffuse.contents = imageName;
    
    //turn on mipmapping
    block.geometry.firstMaterial.diffuse.mipFilter = SCNFilterModeLinear;
    
    //make it physically based
    block.physicsBody = [SCNPhysicsBody dynamicBody];
    
    //add to the scene
    [[scene rootNode] addChildNode:block];
}

- (void)setupSceneElements:(SCNScene *)scene
{
    scene.physicsWorld.contactDelegate = self;
    
    // add a train
    [self addTrainToScene:scene atPosition:SCNVector3Make(-5, 20, -40)];
    
    // add wooden blocks
   // [self addWoodenBlockToScene:scene withImageNamed:@"WoodCubeA.jpg" atPosition:SCNVector3Make(-10, 15, 10)];
   // [self addWoodenBlockToScene:scene withImageNamed:@"WoodCubeB.jpg" atPosition:SCNVector3Make( -9, 10, 10)];
   // [self addWoodenBlockToScene:scene withImageNamed:@"WoodCubeC.jpg" atPosition:SCNVector3Make(20, 15, -11)];
    //[self addWoodenBlockToScene:scene withImageNamed:@"WoodCubeA.jpg" atPosition:SCNVector3Make(25, 5, -20)];
    
    // add walls
    
    _currentWalls = [[NSMutableArray alloc] init];
    _nextWalls = [[NSMutableArray alloc] init];
    
    SCNNode *wall = [SCNNode nodeWithGeometry:[SCNPlane planeWithWidth:500 height:100]];
    wall.geometry.firstMaterial.diffuse.contents = @"wall.jpg";
    wall.geometry.firstMaterial.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(24, 2, 1), SCNMatrix4MakeTranslation(0, 1, 0));
    wall.geometry.firstMaterial.diffuse.wrapS = SCNWrapModeRepeat;
    wall.geometry.firstMaterial.diffuse.wrapT = SCNWrapModeMirror;
    wall.geometry.firstMaterial.doubleSided = YES;
    wall.castsShadow = NO;
    wall.geometry.firstMaterial.locksAmbientWithDiffuse = YES;
        
    wall.position = SCNVector3Make(0, 50, -92);
    wall.physicsBody = [SCNPhysicsBody staticBody];
    //[scene.rootNode addChildNode:wall];
    
    
    
    wall = [wall clone];
    wall.position = SCNVector3Make(0, 50, -200);
    wall.rotation = SCNVector4Make(0, 1, 0, M_PI_2);
    [scene.rootNode addChildNode:wall];
    
    [_currentWalls addObject:wall];
    
    wall = [wall clone];
    wall.position = SCNVector3Make(48, 50, -200);
    wall.rotation = SCNVector4Make(0, 1, 0, -M_PI_2);
    [scene.rootNode addChildNode:wall];
    
    [_currentWalls addObject:wall];
    
    wall = [wall clone];
    wall.geometry.firstMaterial.diffuse.contents = @"carpet.jpg";
    wall.position = SCNVector3Make(0, 50, -450);
    wall.rotation = SCNVector4Make(0, 1, 0, M_PI_2);
    [scene.rootNode addChildNode:wall];
    
    [_nextWalls addObject:wall];
    
    wall = [wall clone];
    wall.geometry.firstMaterial.diffuse.contents = @"carpet.jpg";
    wall.position = SCNVector3Make(48, 50, -450);
    wall.rotation = SCNVector4Make(0, 1, 0, M_PI_2);
    [scene.rootNode addChildNode:wall];
    
    [_nextWalls addObject:wall];
    
    /*SCNNode *backWall = [SCNNode nodeWithGeometry:[SCNPlane planeWithWidth:400 height:100]];
    backWall.geometry.firstMaterial = wall.geometry.firstMaterial;
    backWall.position = SCNVector3Make(0, 50, 200);
    backWall.rotation = SCNVector4Make(0, 1, 0, M_PI);
    backWall.castsShadow = NO;
    backWall.physicsBody = [SCNPhysicsBody staticBody];
    [scene.rootNode addChildNode:backWall];*/
    
    // add ceil
    SCNNode *ceilNode = [SCNNode nodeWithGeometry:[SCNPlane planeWithWidth:400 height:400]];
    ceilNode.position = SCNVector3Make(0, 100, 0);
    ceilNode.rotation = SCNVector4Make(1, 0, 0, M_PI_2);
    ceilNode.geometry.firstMaterial.doubleSided = NO;
    ceilNode.castsShadow = NO;
    ceilNode.geometry.firstMaterial.locksAmbientWithDiffuse = YES;
    [scene.rootNode addChildNode:ceilNode];
    
    //add more block
  /*  for(int i=0;i<4; i++) {
        [self addWoodenBlockToScene:scene withImageNamed:@"WoodCubeA.jpg" atPosition:SCNVector3Make(rand()%60 - 30, 20, rand()%40 - 20)];
        [self addWoodenBlockToScene:scene withImageNamed:@"WoodCubeB.jpg" atPosition:SCNVector3Make(rand()%60 - 30, 20, rand()%40 - 20)];
        [self addWoodenBlockToScene:scene withImageNamed:@"WoodCubeC.jpg" atPosition:SCNVector3Make(rand()%60 - 30, 20, rand()%40 - 20)];
    }
    
    // add cartoon book
    SCNNode *block = [SCNNode node];
    block.position = SCNVector3Make(20, 10, -16);
    block.rotation = SCNVector4Make(0, 1, 0, -M_PI_4);
    block.geometry = [SCNBox boxWithWidth:22 height:0.2 length:34 chamferRadius:0];
    SCNMaterial *frontMat = [SCNMaterial material];
    frontMat.locksAmbientWithDiffuse = YES;
    frontMat.diffuse.contents = @"book_front.jpg";
    frontMat.diffuse.mipFilter = SCNFilterModeLinear;
    SCNMaterial *backMat = [SCNMaterial material];
    backMat.locksAmbientWithDiffuse = YES;
    backMat.diffuse.contents = @"book_back.jpg";
    backMat.diffuse.mipFilter = SCNFilterModeLinear;
    block.geometry.materials = @[frontMat, backMat];
    block.physicsBody = [SCNPhysicsBody dynamicBody];
    [[scene rootNode] addChildNode:block]; */
    
    // add carpet
   /* SCNNode *rug = [SCNNode node];
    rug.position = SCNVector3Make(0, 0.01, 0);
    rug.rotation = SCNVector4Make(1, 0, 0, M_PI_2);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(-50, -30, 100, 50) cornerRadius:2.5];
    path.flatness = 0.1;
    rug.geometry = [SCNShape shapeWithPath:path extrusionDepth:0.05];
    rug.geometry.firstMaterial.locksAmbientWithDiffuse = YES;
    rug.geometry.firstMaterial.diffuse.contents = @"carpet.jpg";
    [[scene rootNode] addChildNode:rug];*/
    
    // add ball
  /*  SCNNode *ball = [SCNNode node];
    ball.position = SCNVector3Make(-5, 5, -18);
    ball.geometry = [SCNSphere sphereWithRadius:5];
    ball.geometry.firstMaterial.locksAmbientWithDiffuse = YES;
    ball.geometry.firstMaterial.diffuse.contents = @"ball.jpg";
    ball.geometry.firstMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(2, 1, 1);
    ball.geometry.firstMaterial.diffuse.wrapS = SCNWrapModeMirror;
    ball.physicsBody = [SCNPhysicsBody dynamicBody];
    ball.physicsBody.restitution = 0.9;
    [[scene rootNode] addChildNode:ball];*/
}


- (SCNNode *)setupVehicle:(SCNScene *)scene
{
    SCNScene *carScene = [SCNScene sceneNamed:@"rc_car"];
    SCNNode *chassisNode = [carScene.rootNode childNodeWithName:@"rccarBody" recursively:YES];
    
    // setup the chassis
    chassisNode.position = SCNVector3Make(24, 2, 30);
    chassisNode.rotation = SCNVector4Make(0, 1, 0, M_PI);
    
    SCNPhysicsBody *body = [SCNPhysicsBody dynamicBody];
    body.allowsResting = NO;
    body.mass = 150;
    body.restitution = 0.1;
    body.friction = 1;
    body.rollingFriction = 1;
    
    chassisNode.physicsBody = body;
    [scene.rootNode addChildNode:chassisNode];
    
    SCNParticleSystem *system = [SCNParticleSystem particleSystemNamed:@"Explosion" inDirectory:nil];
    SCNNode *systemNode = [[SCNNode alloc] init];
    [systemNode addParticleSystem:system];
    systemNode.position = chassisNode.position;
    [_scene.rootNode addParticleSystem:systemNode];
    
    SCNNode *pipeNode = [chassisNode childNodeWithName:@"pipe" recursively:YES];
    _reactor = [SCNParticleSystem particleSystemNamed:@"MyParticleSystem" inDirectory:nil];
    _reactorDefaultBirthRate = _reactor.birthRate;
    _reactor.birthRate = 100;
    [pipeNode addParticleSystem:_reactor];
    
    //add wheels wheel_rear_left
    SCNNode *wheel0Node = [chassisNode childNodeWithName:@"wheelLocator_FL" recursively:YES];
    SCNNode *wheel1Node = [chassisNode childNodeWithName:@"wheelLocator_FR" recursively:YES];
    SCNNode *wheel2Node = [chassisNode childNodeWithName:@"wheelLocator_RL" recursively:YES];
    SCNNode *wheel3Node = [chassisNode childNodeWithName:@"wheelLocator_RR" recursively:YES];
    
    SCNPhysicsVehicleWheel *wheel0 = [SCNPhysicsVehicleWheel wheelWithNode:wheel0Node];
    SCNPhysicsVehicleWheel *wheel1 = [SCNPhysicsVehicleWheel wheelWithNode:wheel1Node];
    SCNPhysicsVehicleWheel *wheel2 = [SCNPhysicsVehicleWheel wheelWithNode:wheel2Node];
    SCNPhysicsVehicleWheel *wheel3 = [SCNPhysicsVehicleWheel wheelWithNode:wheel3Node];

    wheel2.frictionSlip = 0.4;
    wheel3.frictionSlip = 0.4;
    
    SCNVector3 min, max;
    [wheel1Node getBoundingBoxMin:&min max:&max];
    CGFloat wheelHalfWidth = 0.5 * (max.x - min.x);;
    
    wheel0.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel0Node convertPosition:SCNVector3Zero toNode:chassisNode]) + (vector_float3){wheelHalfWidth, 0.0, 0.0});
    wheel1.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel1Node convertPosition:SCNVector3Zero toNode:chassisNode]) - (vector_float3){wheelHalfWidth, 0.0, 0.0});
    wheel2.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel2Node convertPosition:SCNVector3Zero toNode:chassisNode]) + (vector_float3){wheelHalfWidth, 0.0, 0.0});
    wheel3.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel3Node convertPosition:SCNVector3Zero toNode:chassisNode]) - (vector_float3){wheelHalfWidth, 0.0, 0.0});
    
    // create the physics vehicle
    SCNPhysicsVehicle *vehicle = [SCNPhysicsVehicle vehicleWithChassisBody:chassisNode.physicsBody wheels:@[wheel0, wheel1, wheel2, wheel3]];
    [scene.physicsWorld addBehavior:vehicle];
    
    _vehicle = vehicle;
    
    chassisNode.name = @"car";
    
    return chassisNode;
}

- (void)setupBotVehicle
{
   // if (_vehiclesNodesArray.count < 10) {
        SCNScene *carScene = [SCNScene sceneNamed:@"rc_car"];
        SCNNode *chassisNode = [carScene.rootNode childNodeWithName:@"rccarBody" recursively:YES];
        
        // setup the chassis
        int randomLine = rand() % 4;
        //int randomZDifference = rand() % 10;
        
        chassisNode.position = SCNVector3Make(10*randomLine + 10, 2,_vehicleNode.presentationNode.position.z - 300);
        
        [_vehiclesPowerArray addObject:[NSNumber numberWithInt:100+rand()%6 * 10]];
        
        chassisNode.rotation = SCNVector4Make(0, 1, 0, M_PI);
        
        SCNPhysicsBody *body = [SCNPhysicsBody dynamicBody];
        body.allowsResting = NO;
        body.mass = 150;
        body.restitution = 0.1;
        body.friction = 1;
        body.rollingFriction = 1;
        
        chassisNode.physicsBody = body;
        [_scene.rootNode addChildNode:chassisNode];
        
        SCNNode *wheel0Node = [chassisNode childNodeWithName:@"wheelLocator_FL" recursively:YES];
        SCNNode *wheel1Node = [chassisNode childNodeWithName:@"wheelLocator_FR" recursively:YES];
        SCNNode *wheel2Node = [chassisNode childNodeWithName:@"wheelLocator_RL" recursively:YES];
        SCNNode *wheel3Node = [chassisNode childNodeWithName:@"wheelLocator_RR" recursively:YES];
        
        SCNPhysicsVehicleWheel *wheel0 = [SCNPhysicsVehicleWheel wheelWithNode:wheel0Node];
        SCNPhysicsVehicleWheel *wheel1 = [SCNPhysicsVehicleWheel wheelWithNode:wheel1Node];
        SCNPhysicsVehicleWheel *wheel2 = [SCNPhysicsVehicleWheel wheelWithNode:wheel2Node];
        SCNPhysicsVehicleWheel *wheel3 = [SCNPhysicsVehicleWheel wheelWithNode:wheel3Node];
        
        wheel2.frictionSlip = 0.4;
        wheel3.frictionSlip = 0.4;
        
        SCNVector3 min, max;
        [wheel1Node getBoundingBoxMin:&min max:&max];
        CGFloat wheelHalfWidth = 0.5 * (max.x - min.x);;
        
        wheel0.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel0Node convertPosition:SCNVector3Zero toNode:chassisNode]) + (vector_float3){wheelHalfWidth, 0.0, 0.0});
        wheel1.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel1Node convertPosition:SCNVector3Zero toNode:chassisNode]) - (vector_float3){wheelHalfWidth, 0.0, 0.0});
        wheel2.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel2Node convertPosition:SCNVector3Zero toNode:chassisNode]) + (vector_float3){wheelHalfWidth, 0.0, 0.0});
        wheel3.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel3Node convertPosition:SCNVector3Zero toNode:chassisNode]) - (vector_float3){wheelHalfWidth, 0.0, 0.0});
        
        SCNPhysicsVehicle *vehicle = [SCNPhysicsVehicle vehicleWithChassisBody:chassisNode.physicsBody wheels:@[wheel0, wheel1, wheel2, wheel3]];
        [_scene.physicsWorld addBehavior:vehicle];
        
        [_vehiclesArray addObject:vehicle];
        [_vehiclesNodesArray addObject:chassisNode];
        
        chassisNode.name = @"car";
   // }
}

- (SCNNode *)setupVehicle:(SCNScene *)scene withNumber:(NSInteger)number
{
    SCNScene *carScene = [SCNScene sceneNamed:@"rc_car"];
    SCNNode *chassisNode = [carScene.rootNode childNodeWithName:@"rccarBody" recursively:YES];
    
    // setup the chassis
    int randomLine = rand() % 4;
    int randomZDifference = rand() % 10;
    
    [_vehiclesPowerArray addObject:[NSNumber numberWithInt:100+rand()%6 * 10]];
    
    if (number%2 == 0) {
        chassisNode.position = SCNVector3Make(10*randomLine + 10, 2, -30*number + randomZDifference *2);
    } else {
        chassisNode.position = SCNVector3Make(10*randomLine + 10, 2, -30*number + randomZDifference *2);
    }
    
    chassisNode.rotation = SCNVector4Make(0, 1, 0, M_PI);
    
    SCNPhysicsBody *body = [SCNPhysicsBody dynamicBody];
    body.allowsResting = NO;
    body.mass = 150;
    body.restitution = 0.1;
    body.friction = 1;
    body.rollingFriction = 1;
    
    chassisNode.physicsBody = body;
    [scene.rootNode addChildNode:chassisNode];
    
    SCNNode *wheel0Node = [chassisNode childNodeWithName:@"wheelLocator_FL" recursively:YES];
    SCNNode *wheel1Node = [chassisNode childNodeWithName:@"wheelLocator_FR" recursively:YES];
    SCNNode *wheel2Node = [chassisNode childNodeWithName:@"wheelLocator_RL" recursively:YES];
    SCNNode *wheel3Node = [chassisNode childNodeWithName:@"wheelLocator_RR" recursively:YES];
    
    SCNPhysicsVehicleWheel *wheel0 = [SCNPhysicsVehicleWheel wheelWithNode:wheel0Node];
    SCNPhysicsVehicleWheel *wheel1 = [SCNPhysicsVehicleWheel wheelWithNode:wheel1Node];
    SCNPhysicsVehicleWheel *wheel2 = [SCNPhysicsVehicleWheel wheelWithNode:wheel2Node];
    SCNPhysicsVehicleWheel *wheel3 = [SCNPhysicsVehicleWheel wheelWithNode:wheel3Node];
    
    wheel2.frictionSlip = 0.4;
    wheel3.frictionSlip = 0.4;
    
    SCNVector3 min, max;
    [wheel1Node getBoundingBoxMin:&min max:&max];
    CGFloat wheelHalfWidth = 0.5 * (max.x - min.x);;
    
    wheel0.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel0Node convertPosition:SCNVector3Zero toNode:chassisNode]) + (vector_float3){wheelHalfWidth, 0.0, 0.0});
    wheel1.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel1Node convertPosition:SCNVector3Zero toNode:chassisNode]) - (vector_float3){wheelHalfWidth, 0.0, 0.0});
    wheel2.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel2Node convertPosition:SCNVector3Zero toNode:chassisNode]) + (vector_float3){wheelHalfWidth, 0.0, 0.0});
    wheel3.connectionPosition = SCNVector3FromFloat3(SCNVector3ToFloat3([wheel3Node convertPosition:SCNVector3Zero toNode:chassisNode]) - (vector_float3){wheelHalfWidth, 0.0, 0.0});
    
    SCNPhysicsVehicle *vehicle = [SCNPhysicsVehicle vehicleWithChassisBody:chassisNode.physicsBody wheels:@[wheel0, wheel1, wheel2, wheel3]];
    [scene.physicsWorld addBehavior:vehicle];
    
    [_vehiclesArray addObject:vehicle];
    [_vehiclesNodesArray addObject:chassisNode];
    
    chassisNode.name = @"car";
    
    return chassisNode;
}

- (void)setupVehiclesWithScene:(SCNScene *)scene
{
    _vehiclesArray = [[NSMutableArray alloc] init];
    _vehiclesNodesArray = [[NSMutableArray alloc] init];
    for (int i = 0; i<20; i++) {
        [self setupVehicle:scene withNumber:i];
    }
}

- (SCNScene *)setupScene
{
    // create a new scene
    SCNScene *scene = [SCNScene scene];
    
    //global environment
    [self setupEnvironment:scene];
    
    //add elements
    [self setupSceneElements:scene];
    
    //setup vehicle
    _vehicleNode = [self setupVehicle:scene];
    //_vehicleNode2 = [self setupVehicle2:scene];
    
    [self setupVehiclesWithScene:scene];
    
    //create a main camera
    _cameraNode = [[SCNNode alloc] init];
    _cameraNode.camera = [SCNCamera camera];
    _cameraNode.camera.zFar = 500;
    _cameraNode.position = SCNVector3Make(0, 60, 50);
    _cameraNode.rotation  = SCNVector4Make(1, 0, 0, -M_PI_4*0.75);
    [scene.rootNode addChildNode:_cameraNode];
    
    //add a secondary camera to the car
    SCNNode *frontCameraNode = [SCNNode node];
    frontCameraNode.position = SCNVector3Make(0, 3.5, 2.5);
    frontCameraNode.rotation = SCNVector4Make(0, 1, 0, M_PI);
    frontCameraNode.camera = [SCNCamera camera];
    frontCameraNode.camera.xFov = 75;
    frontCameraNode.camera.zFar = 500;
    
    [_vehicleNode addChildNode:frontCameraNode];
    
    
    _scene = scene;
    return scene;
}

- (void)setupAccelerometer
{
    //event
    _motionManager = [[CMMotionManager alloc] init];
    AAPLGameViewController * __weak weakSelf = self;
    
    if ([[GCController controllers] count] == 0 && [_motionManager isAccelerometerAvailable] == YES) {
        [_motionManager setAccelerometerUpdateInterval:1/60.0];
        [_motionManager startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMAccelerometerData *accelerometerData, NSError *error) {
            [weakSelf accelerometerDidChange:accelerometerData.acceleration];
        }];
    }
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
 
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(setupBotVehicle) userInfo:nil repeats:YES];
    
    _gear = 1;
    _vehiclesPowerArray = [[NSMutableArray alloc] init];
    
    [[UIApplication sharedApplication] setStatusBarHidden:YES];
    
    SCNView *scnView = (SCNView *) self.view;
    
    //set the background to back
    scnView.backgroundColor = [SKColor yellowColor];
    
    //setup the scene
    SCNScene *scene = [self setupScene];
    
    //present it
    scnView.scene = scene;
    
    //tweak physics
    scnView.scene.physicsWorld.speed = 4.0;

    //setup overlays
    scnView.overlaySKScene = [[AAPLOverlayScene alloc] initWithSize:scnView.bounds.size];
    
    //setup accelerometer
    [self setupAccelerometer];
    
    //initial point of view
    scnView.pointOfView = _cameraNode;
    
    //plug game logic
    scnView.delegate = self;
    
    
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.numberOfTouchesRequired = 2;
    scnView.gestureRecognizers = @[doubleTap];
    
    [super viewDidLoad];
}

- (void)addCar
{
    
}

- (void) handleDoubleTap:(UITapGestureRecognizer *) gesture
{
    SCNScene *scene = [self setupScene];
    
    SCNView *scnView = (SCNView *) self.view;
    //present it
    scnView.scene = scene;
    
    //tweak physics
    scnView.scene.physicsWorld.speed = 4.0;
    
    //initial point of view
    scnView.pointOfView = _cameraNode;
    
    ((AAPLGameView*)scnView).touchCount = 0;
}

// game logic
- (void)renderer:(id<SCNSceneRenderer>)aRenderer didSimulatePhysicsAtTime:(NSTimeInterval)time
{
   
    NSMutableArray *objectsToDelete = [[NSMutableArray alloc]init];
    
    for (SCNNode *vehicleNode in _vehiclesNodesArray) {
        if (vehicleNode.presentationNode.position.z > _vehicleNode.presentationNode.position.z) {
            [objectsToDelete addObject:vehicleNode];
        }
    }
    
    if (objectsToDelete.count) {
        for (SCNNode *node in objectsToDelete) {
            NSUInteger indexToDelete = [_vehiclesNodesArray indexOfObject:node];
            [_vehiclesNodesArray[indexToDelete] removeFromParentNode];
            //_vehiclesArray[indexToDelete] = nil;
        }
    }
    
    
    //float defaultEngineForce = 100.0;
    const float defaultBrakingForce = 1.0;
    const float steeringClamp = 0.3;
    const float cameraDamping = 0.1;
    
    CGFloat engineForce = 0;
    CGFloat brakingForce = 0;
    
    AAPLGameView *scnView = (AAPLGameView*)self.view;
    
    brakingForce = 1000;
    
    if (scnView.braking) {
        brakingForce = 1000;
    }
    
    float defaultEngineForce = 500;
    
    if (_gear == 0) {
        brakingForce = 2;
    }
    
    if (_gear == 1) {
        defaultEngineForce = 100;
    }
    
    if (_gear == 2) {
        defaultEngineForce = 200;
    }
    
    if (_gear == 3) {
        defaultEngineForce = 300;
    }
    
    if (_gear == 4) {
        defaultEngineForce = 500;
    }
    
    
    
    if (_vehicle.speedInKilometersPerHour > 20 && _gear == 1) {
        _gear = 0;
    }
    
    if (_vehicle.speedInKilometersPerHour < 17 && _gear == 0) {
        defaultEngineForce = 250;
        _gear = 2;
    }
    
    if (_vehicle.speedInKilometersPerHour > 50 && _gear == 2) {
        _gear = 0;
    }
    
    if (_vehicle.speedInKilometersPerHour < 47 &&_vehicle.speedInKilometersPerHour > 25 && _gear == 0) {
        _gear = 3;
    }
    
    if (_vehicle.speedInKilometersPerHour > 100 && _gear == 3) {
        _gear = 0;
    }
    
    if (_vehicle.speedInKilometersPerHour < 97 &&_vehicle.speedInKilometersPerHour > 55 && _gear == 0) {
        _gear = 4;
    }
    
    NSArray* controllers = [GCController controllers];
    
    float orientation = _orientation;
    
    //drive: 1 touch = accelerate, 2 touches = backward, 3 touches = brake
    if (scnView.touchCount == 1) {
        engineForce = defaultEngineForce;
        _reactor.birthRate = _reactorDefaultBirthRate;
    }
    else if (scnView.touchCount == 2) {
        engineForce = -defaultEngineForce;
        _reactor.birthRate = 0;
    }
    else if (scnView.touchCount == 3) {
        brakingForce = 1;
        _reactor.birthRate = 0;
    }
    else {
        brakingForce = defaultBrakingForce;
        _reactor.birthRate = 0;
    }
    
    //controller support
    if (controllers && [controllers count] > 0) {
        GCController *controller = controllers[0];
        GCGamepad *pad = [controller gamepad];
        GCControllerDirectionPad *dpad = [pad dpad];
        
        static float orientationCum = 0;
        
#define INCR_ORIENTATION 0.03
#define DECR_ORIENTATION 0.8
        
        if (dpad.right.pressed) {
            if (orientationCum < 0) orientationCum *= DECR_ORIENTATION;
            orientationCum += INCR_ORIENTATION;
            if (orientationCum > 1) orientationCum = 1;
        }
        else if (dpad.left.pressed) {
            if (orientationCum > 0) orientationCum *= DECR_ORIENTATION;
            orientationCum -= INCR_ORIENTATION;
            if (orientationCum < -1) orientationCum = -1;
        }
        else {
            orientationCum *= DECR_ORIENTATION;
        }
        
        orientation = orientationCum;
        
        if (pad.buttonX.pressed) {
            engineForce = defaultEngineForce;
            brakingForce = defaultBrakingForce;
            _reactor.birthRate = _reactorDefaultBirthRate;
        }
        else if (pad.buttonA.pressed) {
            engineForce = -defaultEngineForce;
            _reactor.birthRate = 0;
        }
        else if (pad.buttonB.pressed) {
            brakingForce = 100;
            _reactor.birthRate = 0;
        }
        else {
            brakingForce = defaultBrakingForce;
            _reactor.birthRate = 0;
        }
    }
    
    _vehicleSteering = -orientation;
    if (orientation==0)
        _vehicleSteering *= 0.3;
    if (_vehicleSteering < -steeringClamp)
        _vehicleSteering = -steeringClamp;
    if (_vehicleSteering > steeringClamp)
        _vehicleSteering = steeringClamp;
    
    
   // engineForce = 100;
    
    NSArray *wheels = [_vehicle wheels];
    
    if (scnView.touchCount == 1) {
        brakingForce= 0;
        engineForce = 500;
    }
    
    if (scnView.touchCount == 2) {
        engineForce = 20500;
        brakingForce= 0;
        SCNPhysicsVehicleWheel *wheel1 = wheels[2];
        SCNPhysicsVehicleWheel *wheel2 = wheels[3];
        SCNPhysicsVehicleWheel *wheel3 = wheels[0];
        SCNPhysicsVehicleWheel *wheel4 = wheels[1];
        wheel1.frictionSlip = 0.1;
        wheel2.frictionSlip = 0.1;
        wheel3.frictionSlip = 0.2;
        wheel4.frictionSlip = 0.2;
    }
    
    //update the vehicle steering and acceleration
    [_vehicle setSteeringAngle:_vehicleSteering forWheelAtIndex:0];
    [_vehicle setSteeringAngle:_vehicleSteering forWheelAtIndex:1];
    
    [_vehicle applyEngineForce:engineForce forWheelAtIndex:2];
    [_vehicle applyEngineForce:engineForce forWheelAtIndex:3];
    
    [_vehicle applyBrakingForce:brakingForce forWheelAtIndex:2];
    [_vehicle applyBrakingForce:brakingForce forWheelAtIndex:3];
    
    for (SCNPhysicsVehicle *botVehicle in _vehiclesArray) {
        NSUInteger vehiclePower = [_vehiclesArray indexOfObject:botVehicle];
        [botVehicle applyEngineForce:[_vehiclesPowerArray[vehiclePower] floatValue] forWheelAtIndex:2];
        [botVehicle applyEngineForce:[_vehiclesPowerArray[vehiclePower] floatValue] forWheelAtIndex:3];
    } 
        
    //check if the car is upside down
    [self reorientCarIfNeeded];

    // make camera follow the car node
    SCNNode *car = [_vehicleNode presentationNode];
    SCNVector3 carPos = car.position;
    vector_float3 targetPos = {carPos.x, 30., carPos.z + 25.};
    vector_float3 cameraPos = SCNVector3ToFloat3(_cameraNode.position);
    cameraPos = vector_mix(cameraPos, targetPos, (vector_float3)(cameraDamping));
    _cameraNode.position = SCNVector3FromFloat3(cameraPos);
    
    if (scnView.inCarView) {
        //move spot light in front of the camera
        SCNVector3 frontPosition = [scnView.pointOfView.presentationNode convertPosition:SCNVector3Make(0, 0, -30) toNode:nil];
        _spotLightNode.position = SCNVector3Make(frontPosition.x, 80., frontPosition.z);
        _spotLightNode.rotation = SCNVector4Make(1,0,0,-M_PI/2);
    }
    else {
        //move spot light on top of the car
        _spotLightNode.position = SCNVector3Make(carPos.x, 80., carPos.z + 30.);
        _spotLightNode.rotation = SCNVector4Make(1,0,0,-M_PI/2.8);
    }
    
    SCNVector3 wallPosition = [(SCNNode *)_currentWalls[0] presentationNode].position;
    
    if (_vehicleNode.presentationNode.position.z < wallPosition.z - 300) {
        
        SCNVector3 nextWallPosition = [(SCNNode *)_nextWalls[0] position];
        SCNNode *wall = [(SCNNode *)_currentWalls[1] clone];
        
        for (SCNNode *node in _currentWalls) {
            [node removeFromParentNode];
        }
        _currentWalls = _nextWalls;
        _nextWalls = [[NSMutableArray alloc] init];
        
        wall.position = SCNVector3Make(0, 50,nextWallPosition.z-500);
        wall.rotation = SCNVector4Make(0, 1, 0, M_PI_2);
        [_scene.rootNode addChildNode:wall];
        [_nextWalls addObject:wall];
        
        wall = [wall clone];
        wall.position = SCNVector3Make(48, 50, nextWallPosition.z-500);
        wall.rotation = SCNVector4Make(0, 1, 0, -M_PI_2);
        [_scene.rootNode addChildNode:wall];
        [_nextWalls addObject:wall];
    }
    
    //speed gauge
    AAPLOverlayScene *overlayScene = (AAPLOverlayScene*)scnView.overlaySKScene;
    overlayScene.speedNeedle.zRotation = -(_vehicle.speedInKilometersPerHour * M_PI / MAX_SPEED);
}

- (void)reorientCarIfNeeded
{
    SCNNode *car = [_vehicleNode presentationNode];
    SCNVector3 carPos = car.position;

    // make sure the car isn't upside down, and fix it if it is
    static int ticks = 0;
    static int check = 0;
    ticks++;
    if (ticks == 30) {
        SCNMatrix4 t = car.worldTransform;
        if (t.m22 <= 0.1) {
            check++;
            if (check == 3) {
                static int try = 0;
                try++;
                if (try == 3) {
                    try = 0;
                    
                    //hard reset
                    _vehicleNode.rotation = SCNVector4Make(0, 0, 0, 0);
                    _vehicleNode.position = SCNVector3Make(carPos.x, carPos.y + 10, carPos.z);
                    [_vehicleNode.physicsBody resetTransform];
                }
                else {
                    //try to upturn with an random impulse
                    SCNVector3 pos = SCNVector3Make(-10*((rand()/(float)RAND_MAX)-0.5),0,-10*((rand()/(float)RAND_MAX)-0.5));
                    [_vehicleNode.physicsBody applyForce:SCNVector3Make(0, 300, 0) atPosition:pos impulse:YES];
                }
                
                check = 0;
            }
        }
        else {
            check = 0;
        }
        
        ticks=0;
    }
}

- (void)accelerometerDidChange:(CMAcceleration)acceleration
{
#define kFilteringFactor			0.5
    
    //Use a basic low-pass filter to only keep the gravity in the accelerometer values
    _accelerometer[0] = acceleration.x * kFilteringFactor + _accelerometer[0] * (1.0 - kFilteringFactor);
    _accelerometer[1] = acceleration.y * kFilteringFactor + _accelerometer[1] * (1.0 - kFilteringFactor);
    _accelerometer[2] = acceleration.z * kFilteringFactor + _accelerometer[2] * (1.0 - kFilteringFactor);
    
    if (_accelerometer[0] > 0) {
        _orientation = _accelerometer[1]*1.3;
    }
    else {
        _orientation = -_accelerometer[1]*1.3;
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [_motionManager stopAccelerometerUpdates];
    _motionManager = nil;
}

- (BOOL)shouldAutorotate
{
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskLandscape;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

- (void)physicsWorld:(SCNPhysicsWorld *)world didUpdateContact:(SCNPhysicsContact *)contact
{
    if ([contact.nodeA.name isEqualToString:@"car"] && [contact.nodeB.name isEqualToString:@"car"]) {
        
        if (contact.nodeA.physicsBody.velocity.z > contact.nodeB.physicsBody.velocity.z + 7 || contact.nodeA.physicsBody.velocity.z + 7 <  contact.nodeB.physicsBody.velocity.z) {
            SCNParticleSystem *system = [SCNParticleSystem particleSystemNamed:@"Explosion" inDirectory:nil];
            SCNNode *systemNode = [[SCNNode alloc] init];
            [systemNode addParticleSystem:system];
            
            SCNVector3 positionOfExplosion = SCNVector3Make((contact.nodeA.presentationNode.position.x + contact.nodeB.presentationNode.position.x)/2, (contact.nodeA.presentationNode.position.y + contact.nodeB.presentationNode.position.y)/2, (contact.nodeA.presentationNode.position.z + contact.nodeB.presentationNode.position.z)/2);
            
            systemNode.position = positionOfExplosion;
            [_scene.rootNode addChildNode:systemNode];
            
            [contact.nodeA removeFromParentNode];
            [contact.nodeB removeFromParentNode];
        }

    }
}

@end
