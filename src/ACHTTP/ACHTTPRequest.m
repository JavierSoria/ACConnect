//
//  ACHTTPRequest.m
//  Strine
//
//  Created by Jason Kichline on 10/20/09.
//  Copyright 2009 andCulture. All rights reserved.
//

#import "ACHTTPRequest.h"
#import "ACHTTPReachability.h"
#import "JSONKit.h"
#import "XMLReader.h"

static int _networkActivity = 0;

@protocol ACHTTPRequestDelegate;

@implementation ACHTTPRequest

@synthesize action, response, result, body, payload, url, receivedData, delegate, username, password, method, connection = conn, modifiers;

#pragma mark - Initialization

-(id)init{
	if((self = [super init])) {
		conn = nil;
		method = ACHTTPRequestMethodAutomatic;
	}
	return self;
}

+(ACHTTPRequest*)request {
	return [[[self alloc] init] autorelease];
}

+(ACHTTPRequest*)requestWithDelegate:(id)_delegate {
	ACHTTPRequest* request = [[self alloc] init];
	request.delegate = _delegate;
	return [request autorelease];
}

+(ACHTTPRequest*)requestWithDelegate:(id)_delegate action:(SEL)_action {
	ACHTTPRequest* request = [[self alloc] init];
	request.delegate = _delegate;
	request.action = _action;
	return [request autorelease];
}

+(int)networkActivity {
	return _networkActivity;
}

+(void)incrementNetworkActivity {
	_networkActivity++;
	if(_networkActivity > 0) {
		[[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
	}
}

+(void)decrementNetworkActivity {
	_networkActivity--;
	if(_networkActivity <= 0) {
		[self resetNetworkActivity];
	}
}

+(void)resetNetworkActivity {
	[[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
	_networkActivity = 0;
}

// Sends the request via HTTP.
- (void) getUrl:(id)value {
	
	// Make it a URL if it's not one
	NSURL* newUrl = nil;
	if([value isKindOfClass:[NSURL class]]) {
		newUrl = [value retain];
	} else if([value isKindOfClass:[NSString class]]) {
		newUrl = [[NSURL alloc] initWithString: value];
		if(newUrl == nil) {
			NSLog(@"The URL %@ could not be parsed.", value);
		}
	}
	if([newUrl isKindOfClass:[NSURL class]]) {
		self.url = newUrl;
	}
	if([value isKindOfClass:[NSURLRequest class]]) {
		self.url = [(NSURLRequest*)value URL];
	}
	[newUrl release];
	
	// Make sure the network is available
	if([[ACHTTPReachability reachabilityForInternetConnection] currentReachabilityStatus] == NotReachable) {
		NSError* error = [NSError errorWithDomain:@"ACHTTPRequest" code:400 userInfo:[NSDictionary dictionaryWithObject:@"The network is not available" forKey:NSLocalizedDescriptionKey]];
		[self handleError: error];
		return;
	} else {
		// Make sure we can reach the host
		if([[ACHTTPReachability reachabilityWithHostName:url.host] currentReachabilityStatus] == NotReachable) {
			NSError* error = [NSError errorWithDomain:@"ACHTTPRequest" code:410 userInfo:[NSDictionary dictionaryWithObject:@"The host is not available" forKey:NSLocalizedDescriptionKey]];
			[self handleError: error];
			return;
		}
	}

	// Create the request
	NSMutableURLRequest* request = nil;
	if([value isKindOfClass:[NSURLRequest class]]) {
		request = value;
	} else {
		request = [NSMutableURLRequest requestWithURL:self.url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:30];
	
		// Determine the method of the request
		NSString* httpMethod = @"GET";
		switch (method) {
			case ACHTTPRequestMethodGet:
				httpMethod = @"GET"; break;
			case ACHTTPRequestMethodPost:
				httpMethod = @"POST"; break;
			case ACHTTPRequestMethodPut:
				httpMethod = @"PUT"; break;
			case ACHTTPRequestMethodHead:
				httpMethod = @"HEAD"; break;
			case ACHTTPRequestMethodDelete:
				httpMethod = @"DELETE"; break;
			case ACHTTPRequestMethodTrace:
				httpMethod = @"TRACE"; break;
			default:
				if(self.body != nil) {
					httpMethod = @"POST";
				} else {
					httpMethod = @"GET";
				}
				break;
		}
		[request setHTTPMethod:httpMethod];
		
		// Set body parameters
		if(self.body != nil) {
			if([self.body isKindOfClass:[NSData class]]) {
				[request setHTTPBody:(NSData*)body];
			} else if([self.body isKindOfClass:[NSDictionary class]]) {
				[request setHTTPBody:[[ACHTTPRequest convertDictionaryToParameters:(NSDictionary*)self.body] dataUsingEncoding:NSUTF8StringEncoding]];
			} else {
				[request setHTTPBody:[[NSString stringWithFormat:@"%@", self.body] dataUsingEncoding:NSUTF8StringEncoding]];
			}
		}
	}
	
	// Set body parameters
	if(self.body != nil) {
		if([self.body isKindOfClass:[NSData class]]) {
			[request setHTTPBody:(NSData*)body];
		} else if([self.body isKindOfClass:[NSDictionary class]]) {
			[request setHTTPBody:[[ACHTTPRequest convertDictionaryToParameters:(NSDictionary*)self.body] dataUsingEncoding:NSUTF8StringEncoding]];
		} else {
			[request setHTTPBody:[[NSString stringWithFormat:@"%@", self.body] dataUsingEncoding:NSUTF8StringEncoding]];
		}
	}
	
	// If we have any modifiers specified, run them
	if(self.modifiers != nil) {
		for(id modifier in self.modifiers) {
			if([modifier conformsToProtocol:@protocol(ACHTTPRequestModifier)]) {
				[modifier modifyRequest:request];
			}
		}
	}
	
	// Create the connection
	self.connection = [[NSURLConnection alloc] initWithRequest: request delegate: self];
	[ACHTTPRequest incrementNetworkActivity];
	if(self.connection) {
		self.receivedData = [[NSMutableData alloc] init];
	} else {
		NSError* error = [NSError errorWithDomain:@"ACHTTPRequest" code:404 userInfo: [NSDictionary dictionaryWithObjectsAndKeys: @"Could not create connection", NSLocalizedDescriptionKey,nil]];
		[self handleError: error];
	}
}

// Called when the HTTP socket gets a response.
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)r {
	self.response = (NSHTTPURLResponse*)r;
    [self.receivedData setLength:0];
	
	// Notify the delegate of progress
	if(self.delegate != nil && [(NSObject*)self.delegate respondsToSelector:@selector(httpRequest:updatedProgress:)]) {
		[(NSObject*)self.delegate performSelector:@selector(httpRequest:updatedProgress:) withObject:self withObject:[NSNumber numberWithFloat:0]];
	}
}

// Called when the HTTP socket received data.
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)value {
    [self.receivedData appendData:value];
	if(self.delegate != nil && [(NSObject*)self.delegate respondsToSelector:@selector(httpRequest:updatedProgress:)]) {
		[(NSObject*)self.delegate performSelector:@selector(httpRequest:updatedProgress:) withObject:self withObject:[NSNumber numberWithFloat:(float)self.receivedData.length/(float)self.response.expectedContentLength]];
	}
}

// Called when the HTTP request fails.
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	[ACHTTPRequest decrementNetworkActivity];
	[self.receivedData release];
	[self handleError:error];
}

-(void)handleError:(NSError*)error{
	SEL a = @selector(httpRequest:failedWithError:);
	
	if (self.action != nil && [(NSObject*)self.delegate respondsToSelector:self.action]) {
		[(NSObject*)self.delegate performSelector:self.action withObject:error];
	}
	
	if(self.delegate != nil && [(NSObject*)self.delegate respondsToSelector:a]) {
		[(NSObject*)self.delegate performSelector:action withObject: self withObject: error];
	}
	NSLog(@"%@", error);
}

-(id)result {
	self.result = [ACHTTPRequest resultsWithData:self.receivedData usingMimeType:[self.response MIMEType]];
	return result;
}

// Called when the connection has finished loading.
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	[ACHTTPRequest decrementNetworkActivity];
	if(!self.delegate) { return; }
	
	if (self.action != nil && [(NSObject*)self.delegate respondsToSelector:self.action]) {
		[(NSObject*)self.delegate performSelector:self.action withObject:self];
		return;
	}
	
	if ([(NSObject*)self.delegate respondsToSelector:@selector(httpRequestCompleted)]) {
		[(NSObject*)self.delegate performSelector:@selector(httpRequestCompleted:) withObject: self];
	}

	if(self.delegate && [(NSObject*)self.delegate respondsToSelector:@selector(httpRequest:completedWithData:)]) {
		[(NSObject*)self.delegate performSelector:@selector(httpRequest:completedWithData:) withObject:self withObject:self.receivedData];
	}

	if(self.delegate && [(NSObject*)self.delegate respondsToSelector:@selector(httpRequest:completedWithValue:)]) {
		[(NSObject*)self.delegate performSelector:@selector(httpRequest:completedWithValue:) withObject:self withObject:self.result];
	}
}

// Called if the HTTP request receives an authentication challenge.
-(void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	if([challenge previousFailureCount] == 0) {
		NSURLCredential *newCredential;
        newCredential=[NSURLCredential credentialWithUser:self.username password:self.password persistence:NSURLCredentialPersistenceNone];
        [[challenge sender] useCredential:newCredential forAuthenticationChallenge:challenge];
    } else {
        [[challenge sender] cancelAuthenticationChallenge:challenge];
		NSError* error = [NSError errorWithDomain:@"ACHTTPRequest" code:403 userInfo: [NSDictionary dictionaryWithObjectsAndKeys: @"Could not authenticate this request", NSLocalizedDescriptionKey,nil]];
		[self handleError:error];
    }
}

+(id)resultsWithData:(NSData*)data usingMimeType:(NSString*)mimetype {
	NSString* r = nil;
	id output = nil;
	
	if([mimetype hasPrefix:@"text/"]) {
		r = [[[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] autorelease];
	}
	
	if([r rangeOfString:@"http://www.apple.com/DTDs/PropertyList-1.0.dtd"].length > 0) {
		output = [r propertyList];
	} else {
		if([mimetype hasPrefix:@"application/json"]) {
			output = [r mutableObjectFromJSONString];
		} else if([mimetype hasPrefix:@"application/xml"] || [mimetype hasPrefix:@"text/xml"]) {
			output = [XMLReader dictionaryForXMLData:data error:nil];
		} else if([mimetype hasPrefix:@"text/"]) {
			output = r;
		} else if ([mimetype hasPrefix:@"image/"]) {
			output = [UIImage imageWithData:data];
		} else {
			output = data;
		}
	}
	return output;
	
}

+(id)get:(id)url{
	if([url isKindOfClass:[NSString class]]) {
		url = [NSURL URLWithString:url];
	}
	if([url isKindOfClass:[NSURL class]] == NO) {
		return nil;
	}

	if([[ACHTTPReachability reachabilityForInternetConnection] currentReachabilityStatus] == NotReachable) {
		return nil;
	}
	
	// Make sure we can reach the host
	if([ACHTTPReachability reachabilityWithHostName:[(NSURL*)url host]] == NotReachable) {
		return nil;
	}
	
	NSError* error;
	NSHTTPURLResponse* response;
	[ACHTTPRequest incrementNetworkActivity];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	NSData* resultData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
	
	NSString* resultString = [[[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding] autorelease];
	[ACHTTPRequest decrementNetworkActivity];
	return [ACHTTPRequest resultsWithData:resultData usingMimeType:[response MIMEType]];
}

+(void)get:(id)url delegate: (id<ACHTTPRequestDelegate>) delegate {
	return [self get:url delegate:delegate modifiers:nil];
}

+(void)get:(id)url delegate: (id<ACHTTPRequestDelegate>) delegate modifiers:(NSArray*)modifiers {
	ACHTTPRequest* wd = [[ACHTTPRequest alloc] init];
	wd.delegate = delegate;
	wd.modifiers = modifiers;
	[wd getUrl:url];
	[wd release];
}

+(void)get:(id)url delegate: (id<ACHTTPRequestDelegate>) delegate action:(SEL)action {
	return [self get:url delegate:delegate action:action modifiers:nil];
}

+(void)get:(id)url delegate: (id<ACHTTPRequestDelegate>) delegate action:(SEL)action modifiers:(NSArray*)modifiers {
	ACHTTPRequest* wd = [[ACHTTPRequest alloc] init];
	wd.delegate = delegate;
	wd.action = action;
	wd.modifiers = modifiers;
	[wd getUrl:url];
	[wd release];
}

+(void)post:(id)url data:(id)data delegate:(id <ACHTTPRequestDelegate>)delegate {
	[self post:url data:data delegate:delegate modifiers:nil];
}

+(void)post:(id)url data:(id)data delegate:(id <ACHTTPRequestDelegate>)delegate modifiers:(NSArray*)modifiers {
	ACHTTPRequest* wd = [[ACHTTPRequest alloc] init];
	wd.delegate = delegate;
	wd.body = data;
	wd.modifiers = modifiers;
	[wd getUrl:url];
	[wd release];
}

+(void)post:(id)url data:(id)data delegate:(id <ACHTTPRequestDelegate>)delegate action:(SEL)action {
	return [self post:url data:data delegate:delegate action:action modifiers:nil];
}

+(void)post:(id)url data:(id)data delegate:(id <ACHTTPRequestDelegate>)delegate action:(SEL)action modifiers:(NSArray*)modifiers {
	ACHTTPRequest* wd = [[ACHTTPRequest alloc] init];
	wd.delegate = delegate;
	wd.action = action;
	wd.modifiers = modifiers;
	wd.body = data;
	[wd getUrl:url];
	[wd release];
}

// Cancels the HTTP request.
-(BOOL)cancel{
	if(self.connection == nil) { return NO; }
	[self.connection cancel];
	return YES;
}

+(NSString*)convertDictionaryToParameters:(NSDictionary*)d {
	return [self convertDictionaryToParameters:d separator:nil];
}

+(NSString*)convertDictionaryToParameters:(NSDictionary*)d separator:(NSString*)separator {
	if(separator == nil) { separator = @"."; }
	NSMutableString* s = [NSMutableString string];
	for(id key in [d allKeys]) {
		NSString* value = [NSString stringWithFormat:@"%@", [d objectForKey:key]];
		if(s.length > 0) {
			[s appendString:@"&"];
		}
		[s appendFormat:@"%@=%@", [key stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding], [value stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
	}
	return s;
}

-(void)dealloc{
	[receivedData release];
	[url release];
	[conn release];
	[modifiers release];
	[super dealloc];
}

@end
