/* Implementation of GNUSTEP string class
   Copyright (C) 1995, 1996, 1997, 1998 Free Software Foundation, Inc.
   
   Written by:  Andrew Kachites McCallum <mccallum@gnu.ai.mit.edu>
   Date: January 1995

   Unicode implementation by Stevo Crvenkovski <stevo@btinternet.com>
   Date: February 1997

   Optimisations by Richard Frith-Macdonald <richard@brainstorm.co.uk>
   Date: October 1998 - 2000

   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Library General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111 USA.
*/ 

/* Caveats: 

   Some implementations will need to be changed.
   Does not support all justification directives for `%@' in format strings 
   on non-GNU-libc systems.
*/

/*
   Locales somewhat supported.
   Limited choice of default encodings.
*/

#include <config.h>
#include <stdio.h>
#include <string.h>
#include <base/preface.h>
#include <Foundation/NSString.h>
#include <Foundation/NSCalendarDate.h>
#include <Foundation/NSArray.h>
#include <Foundation/NSCharacterSet.h>
#include <Foundation/NSException.h>
#include <Foundation/NSValue.h>
#include <Foundation/NSDictionary.h>
#include <Foundation/NSUserDefaults.h>
#include <Foundation/NSFileManager.h>
#include <Foundation/NSPortCoder.h>
#include <Foundation/NSPathUtilities.h>
#include <Foundation/NSRange.h>
#include <Foundation/NSException.h>
#include <Foundation/NSData.h>
#include <Foundation/NSBundle.h>
#include <Foundation/NSURL.h>
#include <Foundation/NSMapTable.h>
#include <Foundation/NSLock.h>
#include <Foundation/NSDebug.h>
#include <base/GSFormat.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/types.h>
#include <fcntl.h>
#include <stdio.h>

#include <base/behavior.h>

#include <base/Unicode.h>

@class	GSString;
@class	GSMutableString;
@class	GSPlaceholderString;
@class	GSMutableArray;
@class	GSMutableDictionary;


/*
 * Cache classes and method implementations for speed.
 */
static Class	NSDataClass;
static Class	NSStringClass;
static Class	NSMutableStringClass;

static Class	GSStringClass;
static Class	GSMutableStringClass;
static Class	GSPlaceholderStringClass;

static GSPlaceholderString	*defaultPlaceholderString;
static NSMapTable		*placeholderMap;
static NSLock			*placeholderLock;

static Class	plArray;
static id	(*plAdd)(id, SEL, id) = 0;

static Class	plDictionary;
static id	(*plSet)(id, SEL, id, id) = 0;

static id	(*plAlloc)(Class, SEL, NSZone*) = 0;
static id	(*plInit)(id, SEL, unichar*, unsigned) = 0;

static SEL	plSel;
static SEL	cMemberSel = 0;


#define IS_BIT_SET(a,i) ((((a) & (1<<(i)))) > 0)

static unsigned const char *hexdigitsBitmapRep = NULL;
#define GS_IS_HEXDIGIT(X) IS_BIT_SET(hexdigitsBitmapRep[(X)/8], (X) % 8)

static void setupHexdigits()
{
  if (hexdigitsBitmapRep == NULL)
    {
      NSCharacterSet *hexdigits;
      NSData *bitmap;
      
      hexdigits = [NSCharacterSet characterSetWithCharactersInString:
	@"0123456789abcdefABCDEF"];
      bitmap = RETAIN([hexdigits bitmapRepresentation]);
      hexdigitsBitmapRep = [bitmap bytes];
    }
}

static NSCharacterSet *quotables = nil;
static unsigned const char *quotablesBitmapRep = NULL;
#define GS_IS_QUOTABLE(X) IS_BIT_SET(quotablesBitmapRep[(X)/8], (X) % 8)

static void setupQuotables()
{
  if (quotablesBitmapRep == NULL)
    {
      NSMutableCharacterSet	*s;
      NSData *bitmap;

      s = [[NSCharacterSet characterSetWithCharactersInString:
	@"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz$./_"]
	mutableCopy];
      [s invert];
      quotables = [s copy];
      RELEASE(s);
      bitmap = RETAIN([quotables bitmapRepresentation]);
      quotablesBitmapRep = [bitmap bytes];
    }
}

static unsigned const char *whitespaceBitmapRep = NULL;
#define GS_IS_WHITESPACE(X) IS_BIT_SET(whitespaceBitmapRep[(X)/8], (X) % 8)

static void setupWhitespace()
{
  if (whitespaceBitmapRep == NULL)
    {
      NSCharacterSet *whitespace;
      NSData *bitmap;

/*
  We can not use whitespaceAndNewlineCharacterSet here as this would lead
  to a recursion, as this also reads in a property list.
      whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
*/
      whitespace = [NSCharacterSet characterSetWithCharactersInString:
				    @" \t\r\n\f\b"];

      bitmap = RETAIN([whitespace bitmapRepresentation]);
      whitespaceBitmapRep = [bitmap bytes];
    }
}

/*
 *	Include sequence handling code with instructions to generate search
 *	and compare functions for NSString objects.
 */
#define	GSEQ_STRCOMP	strCompNsNs
#define	GSEQ_STRRANGE	strRangeNsNs
#define	GSEQ_O	GSEQ_NS
#define	GSEQ_S	GSEQ_NS
#include <GSeq.h>


static id	GSPropertyList(NSString *string);
static id	GSPropertyListFromStringsFormat(NSString *string);

#if defined(__MINGW__)
static unichar		pathSepChar = (unichar)'\\';
static NSString		*pathSepString = @"\\";
static NSString		*rootPath = @"C:\\";
#else
static unichar		pathSepChar = (unichar)'/';
static NSString		*pathSepString = @"/";
static NSString		*rootPath = @"/";
#endif

static NSCharacterSet	*myPathSeps = nil;
/*
 *	We can't have a 'pathSeps' variable initialized in the +initialize
 *	method 'cos that would cause recursion.
 */
static NSCharacterSet*
pathSeps()
{
  if (myPathSeps == nil)
    {
#if defined(__MINGW__)
      myPathSeps = [NSCharacterSet characterSetWithCharactersInString: @"/\\"];
#else
      myPathSeps = [NSCharacterSet characterSetWithCharactersInString: @"/"];
#endif
      IF_NO_GC(RETAIN(myPathSeps));
    }
  return myPathSeps;
}

inline static BOOL
pathSepMember(unichar c)
{

#if defined(__MINGW__)
  if (c == (unichar)'\\' || c == (unichar)'/')
#else 
  if (c == (unichar)'/')
#endif 
    {
      return YES;
    }
  else
    {
      return NO;
    }
}



/* Convert a high-low surrogate pair into Unicode scalar code-point */
static inline gsu32
surrogatePairValue(unichar high, unichar low)
{
  return ((high - (unichar)0xD800) * (unichar)400)
    + ((low - (unichar)0xDC00) + (unichar)10000);
}



@implementation NSString

static NSStringEncoding _DefaultStringEncoding;
static const unichar byteOrderMark = 0xFEFF;
static const unichar byteOrderMarkSwapped = 0xFFFE;

/* UTF-16 Surrogate Ranges */
static NSRange  highSurrogateRange = {0xD800, 1024};
static NSRange  lowSurrogateRange = {0xDC00, 1024};


#if HAVE_REGISTER_PRINTF_FUNCTION
#include <stdio.h>
#include <printf.h>
#include <stdarg.h>

/* <sattler@volker.cs.Uni-Magdeburg.DE>, with libc-5.3.9 thinks this 
   flag PRINTF_ATSIGN_VA_LIST should be 0, but for me, with libc-5.0.9, 
   it crashes.  -mccallum

   Apparently GNU libc 2.xx needs this to be 0 also, along with Linux
   libc versions 5.2.xx and higher (including libc6, which is just GNU
   libc). -chung */
#define PRINTF_ATSIGN_VA_LIST			\
       (defined(_LINUX_C_LIB_VERSION_MINOR)	\
	&& _LINUX_C_LIB_VERSION_MAJOR <= 5	\
	&& _LINUX_C_LIB_VERSION_MINOR < 2)

#if ! PRINTF_ATSIGN_VA_LIST
static int
arginfo_func (const struct printf_info *info, size_t n, int *argtypes)
{
  *argtypes = PA_POINTER;
  return 1;
}
#endif /* !PRINTF_ATSIGN_VA_LIST */

static int
handle_printf_atsign (FILE *stream, 
		      const struct printf_info *info,
#if PRINTF_ATSIGN_VA_LIST
		      va_list *ap_pointer)
#elif defined(_LINUX_C_LIB_VERSION_MAJOR)       \
     && _LINUX_C_LIB_VERSION_MAJOR < 6
                      const void **const args)
#else /* GNU libc needs the following. */
                      const void *const *args)
#endif
{
#if ! PRINTF_ATSIGN_VA_LIST
  const void *ptr = *args;
#endif
  id string_object;
  int len;

  /* xxx This implementation may not pay pay attention to as much 
     of printf_info as it should. */

#if PRINTF_ATSIGN_VA_LIST
  string_object = va_arg (*ap_pointer, id);
#else
  string_object = *((id*) ptr);
#endif
  len = fprintf(stream, "%*s",
		(info->left ? - info->width : info->width),
		[[string_object description] lossyCString]);
  return len;
}
#endif /* HAVE_REGISTER_PRINTF_FUNCTION */

+ (void) initialize
{
  /*
   * Flag required as we call this method explicitly from GSBuildStrings()
   * to ensure that NSString is initialised properly.
   */
  static BOOL	beenHere = NO;

  if (self == [NSString class] && beenHere == NO)
    {
      beenHere = YES;
      plSel = @selector(initWithCharacters:length:);
      cMemberSel = @selector(characterIsMember:);
      caiSel = @selector(characterAtIndex:);
      gcrSel = @selector(getCharacters:range:);
      ranSel = @selector(rangeOfComposedCharacterSequenceAtIndex:);

      _DefaultStringEncoding = GetDefEncoding();
      NSStringClass = self;
      [self setVersion: 1];
      NSMutableStringClass = [NSMutableString class];
      NSDataClass = [NSData class];
      GSPlaceholderStringClass = [GSPlaceholderString class];
      GSStringClass = [GSString class];
      GSMutableStringClass = [GSMutableString class];

      /*
       * Set up infrastructure for placeholder strings.
       */
      defaultPlaceholderString = (GSPlaceholderString*)
	NSAllocateObject(GSPlaceholderStringClass, 0, NSDefaultMallocZone());
      placeholderMap = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
	NSNonRetainedObjectMapValueCallBacks, 0);
      placeholderLock = [NSLock new];

#if HAVE_REGISTER_PRINTF_FUNCTION
      if (register_printf_function ('@', 
				    handle_printf_atsign, 
#if PRINTF_ATSIGN_VA_LIST
				    0))
#else
	                            arginfo_func))
#endif
	[NSException raise: NSGenericException
		     format: @"register printf handling of %%@ failed"];
#endif /* HAVE_REGISTER_PRINTF_FUNCTION */
    }
}

+ (id) allocWithZone: (NSZone*)z
{
  if (self == NSStringClass)
    {
      /*
       * For a constant string, we return a placeholder object that can
       * be converted to a real object when its initialisation method
       * is called.
       */
      if (z == NSDefaultMallocZone() || z == 0)
	{
	  /*
	   * As a special case, we can return a placeholder for a string
	   * in the default malloc zone extremely efficiently.
	   */
	  return defaultPlaceholderString;
	}
      else
	{
	  id	obj;

	  /*
	   * For anything other than the default zone, we need to
	   * locate the correct placeholder in the (lock protected)
	   * table of placeholders.
	   */
	  [placeholderLock lock];
	  obj = (id)NSMapGet(placeholderMap, (void*)z);
	  if (obj == nil)
	    {
	      /*
	       * There is no placeholder object for this zone, so we
	       * create a new one and use that.
	       */
	      obj = (id)NSAllocateObject(GSPlaceholderStringClass, 0, z);
	      NSMapInsert(placeholderMap, (void*)z, (void*)obj);
	    }
	  [placeholderLock unlock];
	  return obj;
	}
    }
  else if (GSObjCIsKindOf(self, GSStringClass) == YES)
    {
      [NSException raise: NSInternalInconsistencyException
		  format: @"Called +allocWithZone: on private string class"];
      return nil;	/* NOT REACHED */
    }
  else
    {
      /*
       * For user provided strings, we simply allocate an object of
       * the given class.
       */
      return NSAllocateObject (self, 0, z);
    }
}

// Creating Temporary Strings

+ (id) string
{
  return AUTORELEASE([[self allocWithZone: NSDefaultMallocZone()] init]);
}

+ (id) stringWithString: (NSString*)aString
{
  NSString	*obj;

  obj = [self allocWithZone: NSDefaultMallocZone()];
  obj = [obj initWithString: aString];
  return AUTORELEASE(obj);
}

+ (id) stringWithCharacters: (const unichar*)chars
		     length: (unsigned)length
{
  NSString	*obj;

  obj = [self allocWithZone: NSDefaultMallocZone()];
  obj = [obj initWithCharacters: chars length: length];
  return AUTORELEASE(obj);
}

+ (id) stringWithCString: (const char*) byteString
{
  NSString	*obj;
  unsigned	length = strlen(byteString);

  obj = [self allocWithZone: NSDefaultMallocZone()];
  obj = [obj initWithCString: byteString length: length];
  return AUTORELEASE(obj);
}

+ (id) stringWithCString: (const char*)byteString
		  length: (unsigned)length
{
  NSString	*obj;

  obj = [self allocWithZone: NSDefaultMallocZone()];
  obj = [obj initWithCString: byteString length: length];
  return AUTORELEASE(obj);
}

+ (id) stringWithUTF8String: (const char *)bytes
{
  NSString	*obj;

  obj = [self allocWithZone: NSDefaultMallocZone()];
  obj = [obj initWithUTF8String: bytes];
  return AUTORELEASE(obj);
}

+ (id) stringWithContentsOfFile: (NSString *)path
{
  NSString	*obj;

  obj = [self allocWithZone: NSDefaultMallocZone()];
  obj = [obj initWithContentsOfFile: path];
  return AUTORELEASE(obj);
}

+ (id) stringWithContentsOfURL: (NSURL *)url
{
  NSString	*obj;

  obj = [self allocWithZone: NSDefaultMallocZone()];
  obj = [obj initWithContentsOfURL: url];
  return AUTORELEASE(obj);
}

+ (id) stringWithFormat: (NSString*)format,...
{
  va_list ap;
  id ret;

  va_start(ap, format);
  if (format == nil)
    ret = nil;
  else
    ret = AUTORELEASE([[self allocWithZone: NSDefaultMallocZone()]
      initWithFormat: format arguments: ap]);
  va_end(ap);
  return ret;
}

+ (id) stringWithFormat: (NSString*)format
	      arguments: (va_list)argList
{
  return AUTORELEASE([[self allocWithZone: NSDefaultMallocZone()]
    initWithFormat: format arguments: argList]);
}


// Initializing Newly Allocated Strings

/* This is the designated initializer. */
- (id) initWithCharactersNoCopy: (unichar*)chars
			 length: (unsigned)length
		   freeWhenDone: (BOOL)flag
{
  [self subclassResponsibility: _cmd];
  return self;
}

- (id) initWithCharacters: (const unichar*)chars
		   length: (unsigned)length
{
  if (length > 0)
    {
      int	i;
      BOOL	isAscii = YES;

      if (chars == 0)
	{
	  [NSException raise: NSInvalidArgumentException
		      format: @"nul pointer but non-zero length"];
	}
      for (i = 0; i < length; i++)
	{
	  if (chars[i] >= 128)
	    {
	      isAscii = NO;
	      break;
	    }
	}
      if (isAscii == YES)
	{
	  char	*s;

	  s = NSZoneMalloc(GSObjCZone(self), length);

	  for (i = 0; i < length; i++)
	    {
	      s[i] = (unsigned char)chars[i];
	    }
	  self = [self initWithCStringNoCopy: s
				      length: length
				freeWhenDone: YES];
	}
      else
	{
	  unichar	*s;

	  s = NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*length);

	  memcpy(s, chars, sizeof(unichar)*length);
	  self = [self initWithCharactersNoCopy: s
					 length: length
				   freeWhenDone: YES];
	}
    }
  else
    {
      self = [self initWithCharactersNoCopy: 0 length: 0 freeWhenDone: NO];
    }

  return self;
}

- (id) initWithCStringNoCopy: (char*)byteString
		      length: (unsigned)length
		freeWhenDone: (BOOL)flag
{
  unichar	*buf;

  buf = (unichar*)NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*length);
  length = encode_strtoustr(buf, byteString, length, _DefaultStringEncoding);
  if (flag == YES && byteString != 0)
    {
      NSZoneFree(NSZoneFromPointer(byteString), byteString);
    }
  self = [self initWithCharactersNoCopy: buf length: length freeWhenDone: YES];
  return self;
}

- (id) initWithCString: (const char*)byteString  length: (unsigned)length
{
  if (length > 0)
    {
      char	*s = NSZoneMalloc(GSObjCZone(self), length);

      if (byteString != 0)
	{
	  memcpy(s, byteString, length);
	}
      self = [self initWithCStringNoCopy: s length: length freeWhenDone: YES];
    }
  else
    {
      self = [self initWithCStringNoCopy: 0 length: 0 freeWhenDone: NO];
    }

  return self;
}

- (id) initWithCString: (const char*)byteString
{
  return [self initWithCString: byteString 
    length: (byteString ? strlen(byteString) : 0)];
}

- (id) initWithString: (NSString*)string
{
  unsigned	length = [string length];

  if (length > 0)
    {
      unichar	*s = NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*length);

      [string getCharacters: s];
      self = [self initWithCharactersNoCopy: s
				     length: length
			       freeWhenDone: YES];
    }
  else
    {
      self = [self initWithCharactersNoCopy: 0
				     length: 0
			       freeWhenDone: NO];
    }
  return self;
}

- (id) initWithUTF8String: (const char *)bytes
{
  unsigned	length = 0;

  if (bytes == NULL)
    {
      NSDebugMLog(@"bytes is NULL");
    }
  else
    {
      length = strlen(bytes);
    }

  if (length > 0)
    {
      unsigned	i;

      /*
       * Check to see if we have in fact got an ascii string
       */
      for (i = 0; i < length; i++)
	{
	  if (((unsigned char*)bytes)[i] > 127)
	    {
	      break;
	    }
	}
      if (i == length)
	{
	  self = [self initWithCString: bytes length: length];
	}
      else
	{
	  unichar	*s;

	  s = NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*length);
	  length = encode_strtoustr(s, bytes, length+1, NSUTF8StringEncoding);
	  self = [self initWithCharactersNoCopy: s
					 length: length
				   freeWhenDone: YES];
	}
    }
  else
    {
      self = [self initWithCharactersNoCopy: 0
				     length: 0
			       freeWhenDone: NO];
    }
  return self;
}

- (id) initWithFormat: (NSString*)format,...
{
  va_list ap;
  va_start(ap, format);
  self = [self initWithFormat: format locale: nil arguments: ap];
  va_end(ap);
  return self;
}

- (id) initWithFormat: (NSString*)format
               locale: (NSDictionary*)locale
{
  return [self initWithFormat: format locale: locale arguments: NULL];
}

- (id) initWithFormat: (NSString*)format
            arguments: (va_list)arg_list
{
  return [self initWithFormat: format locale: nil arguments: arg_list];
}

- (id) initWithFormat: (NSString*)format
               locale: (NSDictionary*)locale
            arguments: (va_list)arg_list
{
  FormatBuf_t	f;
  unichar	*fmt;
  size_t	len;

  len = [format length];
  fmt = objc_malloc((len+1)*sizeof(unichar));
  [format getCharacters: fmt];
  fmt[len] = '\0';
  f.z = NSDefaultMallocZone();
  f.buf = NSZoneMalloc(f.z, 100*sizeof(unichar));
  f.len = 0;
  f.size = 100;
  GSFormat(&f, fmt, arg_list, locale);
  objc_free(fmt);
  // don't use noCopy because f.size > f.len!
  self = [self initWithCharacters: f.buf length: f.len];
  NSZoneFree(f.z, f.buf);
  return self;
}

#if 0
/* xxx Change this when we have non-CString classes */
- (id) initWithFormat: (NSString*)format
               locale: (NSDictionary*)locale
            arguments: (va_list)arg_list
{
#if defined(HAVE_VSPRINTF) || defined(HAVE_VASPRINTF)
  const char *format_cp = [format lossyCString];
  int format_len = strlen (format_cp);
#if HAVE_VASPRINTF
  char *buf;
  int printed_len = 0;
  NSString *ret;

#if ! HAVE_REGISTER_PRINTF_FUNCTION
  NSZone *z = GSObjCZone(self);

  /* If the available libc doesn't have `register_printf_function()', then
     the `%@' printf directive isn't available with printf() and friends.
     Here we make a feable attempt to handle it. */
  {
    /* We need a local copy since we change it.  (Changing and undoing
       the change doesn't work because some format strings are constant
       strings, placed in a non-writable section of the executable, and 
       writing to them will cause a segfault.) */ 
    char format_cp_copy[format_len+1];
    char *atsign_pos;	     /* points to a location inside format_cp_copy */
    char *format_to_go = format_cp_copy;
    char *buf_l;
#define _PRINTF_BUF_LEN 256
    int printed_local_len, avail_len = _PRINTF_BUF_LEN;
    int cstring_len;

    buf = NSZoneMalloc(z, _PRINTF_BUF_LEN);
    strcpy (format_cp_copy, format_cp);
    /* Loop once for each `%@' in the format string. */
    while ((atsign_pos = strstr (format_to_go, "%@")))
      {
        const char *cstring;
        char *formatter_pos; // Position for formatter.
        
        /* If there is a "%%@", then do the right thing: print it literally. */
        if ((*(atsign_pos-1) == '%')
            && atsign_pos != format_cp_copy)
          continue;
        /* Temporarily terminate the string before the `%@'. */
        *atsign_pos = '\0';
        /* Print the part before the '%@' */
        printed_local_len = VASPRINTF_LENGTH (vasprintf (&buf_l,
	  format_to_go, arg_list));
        if(buf_l)
          {
            if(avail_len < printed_local_len+1)
              {
                NS_DURING
                  {
                    buf = NSZoneRealloc(z, buf,
		      printed_len+printed_local_len+_PRINTF_BUF_LEN);
                    avail_len += _PRINTF_BUF_LEN;
                  }
                NS_HANDLER
                  {
                    free(buf_l);
                    [localException raise];
                  }
                NS_ENDHANDLER
              }
            memcpy(&buf[printed_len], buf_l, printed_local_len+1);
            avail_len -= printed_local_len;
            printed_len += printed_local_len;
            free(buf_l);
          }
        else
          {
            [NSException raise: NSMallocException
                        format: @"No available memory"];
          }
        /* Skip arguments used in last vsprintf(). */
        while ((formatter_pos = strchr(format_to_go, '%')))
          {
            char *spec_pos; // Position of conversion specifier.
            
            if (*(formatter_pos+1) == '%')
              {
                format_to_go = formatter_pos+2;
                continue;
              }
            spec_pos = strpbrk(formatter_pos+1, "dioxXucsfeEgGpn\0");
            switch (*spec_pos)
              {
#ifndef powerpc
	      /* FIXME: vsprintf on powerpc apparently advances the arg list
             so this doesn't need to be done. Make a more general check 
             for this */
              case 'd': case 'i': case 'o': 
              case 'x': case 'X': case 'u': case 'c': 
                va_arg(arg_list, int);
                break;
              case 's': 
                if (*(spec_pos - 1) == '*')
                  va_arg(arg_list, int*);
                va_arg(arg_list, char*);
                break;
              case 'f': case 'e': case 'E': case 'g': case 'G': 
                va_arg(arg_list, double);
                break;
              case 'p': 
                va_arg(arg_list, void*);
                break;
              case 'n': 
                va_arg(arg_list, int*);
                break;
#endif /* NOT powerpc */
              case '\0': 
                spec_pos--;
                break;
              }
            format_to_go = spec_pos+1;
          }
        /* Get a C-string (char*) from the String object, and print it. */
        cstring = [[(id) va_arg (arg_list, id) description] lossyCString];
        if (!cstring)
          cstring = "<null string>";
        cstring_len = strlen(cstring);

        if(cstring_len)
          {
            if(avail_len < cstring_len+1)
              {
                buf = NSZoneRealloc(z, buf,
                                    printed_len+cstring_len+_PRINTF_BUF_LEN);
                avail_len += _PRINTF_BUF_LEN;
              }
            memcpy(&buf[printed_len], cstring, cstring_len+1);
            avail_len -= cstring_len;
            printed_len += cstring_len;
          }
        /* Skip over this `%@', and look for another one. */
        format_to_go = atsign_pos + 2;
      }
    /* Print the rest of the string after the last `%@'. */
    printed_local_len = VASPRINTF_LENGTH (vasprintf (&buf_l,
      format_to_go, arg_list));
    if(buf_l)
      {
        if(avail_len < printed_local_len+1)
          {
            NS_DURING
              {
                buf = NSZoneRealloc(z, buf,
		  printed_len+printed_local_len+_PRINTF_BUF_LEN);
                avail_len += _PRINTF_BUF_LEN;
              }
            NS_HANDLER
              {
                free(buf_l);
                [localException raise];
              }
            NS_ENDHANDLER
          }
        memcpy(&buf[printed_len], buf_l, printed_local_len+1);
        avail_len -= printed_local_len;
        printed_len += printed_local_len;
        free(buf_l);
      }
    else
      {
        [NSException raise: NSMallocException
                     format: @"No available memory"];
      }
  }
#else /* HAVE_VSPRINTF */
  /* The available libc has `register_printf_function()', so the `%@' 
     printf directive is handled by printf and friends. */
  printed_len = VASPRINTF_LENGTH (vasprintf (&buf, format_cp, arg_list));

  if(!buf)
    {
      [NSException raise: NSMallocException
                   format: @"No available memory"];
    }
#endif /* !HAVE_REGISTER_PRINTF_FUNCTION */

  ret = [self initWithCString: buf];
#if ! HAVE_REGISTER_PRINTF_FUNCTION
  NSZoneFree(z, buf);
#else
  free(buf);
#endif
  return ret;
#else
  /* xxx horrible disgusting BUFFER_EXTRA arbitrary limit; fix this! */
  #define BUFFER_EXTRA 1024*500
  char buf[format_len + BUFFER_EXTRA];
  int printed_len = 0;

#if ! HAVE_REGISTER_PRINTF_FUNCTION
  /* If the available libc doesn't have `register_printf_function()', then
     the `%@' printf directive isn't available with printf() and friends.
     Here we make a feable attempt to handle it. */
  {
    /* We need a local copy since we change it.  (Changing and undoing
       the change doesn't work because some format strings are constant
       strings, placed in a non-writable section of the executable, and 
       writing to them will cause a segfault.) */ 
    char format_cp_copy[format_len+1];
    char *atsign_pos;	     /* points to a location inside format_cp_copy */
    char *format_to_go = format_cp_copy;
    strcpy (format_cp_copy, format_cp);
    /* Loop once for each `%@' in the format string. */
    while ((atsign_pos = strstr (format_to_go, "%@")))
      {
	const char *cstring;
	char *formatter_pos; // Position for formatter.

	/* If there is a "%%@", then do the right thing: print it literally. */
	if ((*(atsign_pos-1) == '%')
	    && atsign_pos != format_cp_copy)
	  continue;
	/* Temporarily terminate the string before the `%@'. */
	*atsign_pos = '\0';
	/* Print the part before the '%@' */
	printed_len += VSPRINTF_LENGTH (vsprintf (buf+printed_len,
						  format_to_go, arg_list));
	/* Skip arguments used in last vsprintf(). */
	while ((formatter_pos = strchr(format_to_go, '%')))
	  {
	    char *spec_pos; // Position of conversion specifier.

	    if (*(formatter_pos+1) == '%')
	      {
		format_to_go = formatter_pos+2;
		continue;
	      }
	    spec_pos = strpbrk(formatter_pos+1, "dioxXucsfeEgGpn\0");
	    switch (*spec_pos)
	      {
#ifndef powerpc
	      /* FIXME: vsprintf on powerpc apparently advances the arg list
	      so this doesn't need to be done. Make a more general check 
	      for this */
	      case 'd': case 'i': case 'o': 
	      case 'x': case 'X': case 'u': case 'c': 
		(void)va_arg(arg_list, int);
		break;
	      case 's': 
		if (*(spec_pos - 1) == '*')
		  (void)va_arg(arg_list, int*);
		(void)va_arg(arg_list, char*);
		break;
	      case 'f': case 'e': case 'E': case 'g': case 'G': 
		(void)va_arg(arg_list, double);
		break;
	      case 'p': 
		(void)va_arg(arg_list, void*);
		break;
	      case 'n': 
		(void)va_arg(arg_list, int*);
		break;
#endif /* NOT powerpc */
	      case '\0': 
		spec_pos--;
		break;
	      }
	    format_to_go = spec_pos+1;
	  }
	/* Get a C-string (char*) from the String object, and print it. */
	cstring = [[(id) va_arg (arg_list, id) description] lossyCString];
	if (!cstring)
	  cstring = "<null string>";
	strcat (buf+printed_len, cstring);
	printed_len += strlen (cstring);
	/* Skip over this `%@', and look for another one. */
	format_to_go = atsign_pos + 2;
      }
    /* Print the rest of the string after the last `%@'. */
    printed_len += VSPRINTF_LENGTH (vsprintf (buf+printed_len,
					      format_to_go, arg_list));
  }
#else
  /* The available libc has `register_printf_function()', so the `%@' 
     printf directive is handled by printf and friends. */
  printed_len = VSPRINTF_LENGTH (vsprintf (buf, format_cp, arg_list));
#endif /* !HAVE_REGISTER_PRINTF_FUNCTION */

  /* Raise an exception if we overran our buffer. */
  NSParameterAssert (printed_len < format_len + BUFFER_EXTRA - 1);
  return [self initWithCString: buf];
#endif /* HAVE_VASPRINTF */
#else /* HAVE_VSPRINTF || HAVE_VASPRINTF */
  [self notImplemented: _cmd];
  return self;
#endif
}
#endif

- (id) initWithData: (NSData*)data
	   encoding: (NSStringEncoding)encoding
{
  if (encoding == NSASCIIStringEncoding
    || encoding == _DefaultStringEncoding)
    {
      unsigned	len = [data length];

      if (len > 0)
	{
	  char	*s = NSZoneMalloc(GSObjCZone(self), len);

	  [data getBytes: s];
	  self = [self initWithCStringNoCopy: s length: len freeWhenDone: YES];
	}
      else
	{
	  self = [self initWithCStringNoCopy: 0 length: 0 freeWhenDone: NO];
	}
      return self;
    } 
  else if (encoding == NSUTF8StringEncoding)
    {
      unsigned		length = [data length];
      const char	*bytes = [data bytes];
      unsigned		i;

      /*
       * Check to see if we have in fact got an ascii string
       */
      for (i = 0; i < length; i++)
	{
	  if (((unsigned char*)bytes)[i] > 127)
	    {
	      break;
	    }
	}
      if (i == length)
	{
	  self = [self initWithCString: bytes length: length];
	}
      else
	{
	  unichar	*u;

	  u = NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*length);
	  length = encode_strtoustr(u, bytes, length+1, NSUTF8StringEncoding);
	  self = [self initWithCharactersNoCopy: u
					 length: length
				   freeWhenDone: YES];
	}
    }
  else
    {
      unsigned	len = [data length];
      unichar	*u;
      unsigned	count;
      const unsigned char *b;

      if (len < 1  ||  (len < 2 && encoding == NSUnicodeStringEncoding))
	{
	  return [self initWithCStringNoCopy: 0 length: 0 freeWhenDone: NO];
	}

      b = [data bytes];
      u = NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*(len+1));
      if (encoding == NSUnicodeStringEncoding)
        {
	  if ((b[0]==0xFE) & (b[1]==0xFF))
	    {
	      for (count = 2; count < (len - 1); count += 2)
		{
		  u[count/2 - 1] = 256*b[count] + b[count + 1];
		}
	    }
	  else
	    {
	      for (count = 2; count < (len - 1); count += 2)
		{
		  u[count/2 - 1] = 256*b[count + 1] + b[count];
		}
	    }
	  count = count/2 - 1;
	}
      else
	{
	  count = encode_strtoustr(u, b, len, encoding);
	}

      self = [self initWithCharactersNoCopy: u length: count freeWhenDone: YES];
    }
  return self;
}

- (id) initWithContentsOfFile: (NSString*)path
{
  NSStringEncoding	enc;
  NSData		*d = [NSDataClass dataWithContentsOfFile: path];
  unsigned int		len = [d length];
  const unichar		*test;

  if (d == nil)
    return nil;

  if (len == 0)
    return @"";

  test = [d bytes];
  if ((test != NULL) && (len > 1)
    && ((test[0] == byteOrderMark) || (test[0] == byteOrderMarkSwapped)))
    {
      /* somebody set up us the BOM! */
      enc = NSUnicodeStringEncoding;
    }
  else
    {
      enc = _DefaultStringEncoding;
    }
  return [self initWithData: d encoding: enc];
}

- (id) initWithContentsOfURL: (NSURL*)url
{
  NSStringEncoding	enc;
  NSData		*d = [NSDataClass dataWithContentsOfURL: url];
  unsigned int		len = [d length];
  const unsigned char	*test;

  if (d == nil)
    return nil;

  if (len == 0)
    return @"";

  test = [d bytes];
  if ((test != NULL) && (len > 1)
    && ((test[0] == byteOrderMark) || (test[0] == byteOrderMarkSwapped)))
    {
      enc = NSUnicodeStringEncoding;
    }
  else
    {
      enc = _DefaultStringEncoding;
    }
  return [self initWithData: d encoding: enc];
}

- (id) init
{
  self = [self initWithCharactersNoCopy: 0 length: 0 freeWhenDone: 0];
  return self;
}

// Getting a String's Length

- (unsigned) length
{
  [self subclassResponsibility: _cmd];
  return 0;
}

// Accessing Characters

- (unichar) characterAtIndex: (unsigned)index
{
  [self subclassResponsibility: _cmd];
  return (unichar)0;
}

/* Inefficient.  Should be overridden */
- (void) getCharacters: (unichar*)buffer
{
  [self getCharacters: buffer range: ((NSRange){0, [self length]})];
  return;
}

/* Inefficient.  Should be overridden */
- (void) getCharacters: (unichar*)buffer
		 range: (NSRange)aRange
{
  unsigned	l = [self length];
  unsigned	i;
  unichar	(*caiImp)(NSString*, SEL, unsigned);

  GS_RANGE_CHECK(aRange, l);

  caiImp = (unichar (*)())[self methodForSelector: caiSel];

  for (i = 0; i < aRange.length; i++)
    {
      buffer[i] = (*caiImp)(self, caiSel, aRange.location + i);
    }
}

// Combining Strings

- (NSString*) stringByAppendingFormat: (NSString*)format,...
{
  va_list	ap;
  id		ret;

  va_start(ap, format);
  ret = [self stringByAppendingString: 
    [NSString stringWithFormat: format arguments: ap]];
  va_end(ap);
  return ret;
}

- (NSString*) stringByAppendingString: (NSString*)aString
{
  unsigned	len = [self length];
  unsigned	otherLength = [aString length];
  NSZone	*z = GSObjCZone(self);
  unichar	*s = NSZoneMalloc(z, (len+otherLength)*sizeof(unichar));
  NSString	*tmp;

  [self getCharacters: s];
  [aString getCharacters: s + len];
  tmp = [[NSStringClass allocWithZone: z] initWithCharactersNoCopy: s
    length: len + otherLength freeWhenDone: YES];
  return AUTORELEASE(tmp);
}

// Dividing Strings into Substrings

- (NSArray*) componentsSeparatedByString: (NSString*)separator
{
  NSRange	search;
  NSRange	complete;
  NSRange	found;
  NSMutableArray *array = [NSMutableArray array];

  search = NSMakeRange (0, [self length]);
  complete = search;
  found = [self rangeOfString: separator];
  while (found.length != 0)
    {
      NSRange current;

      current = NSMakeRange (search.location,
	found.location - search.location);
      [array addObject: [self substringWithRange: current]];

      search = NSMakeRange (found.location + found.length,
	complete.length - found.location - found.length);
      found = [self rangeOfString: separator 
			  options: 0
			    range: search];
    }
  // Add the last search string range
  [array addObject: [self substringWithRange: search]];

  // FIXME: Need to make mutable array into non-mutable array?
  return array;
}

- (NSString*) substringFromIndex: (unsigned)index
{
  return [self substringWithRange: ((NSRange){index, [self length]-index})];
}

- (NSString*) substringToIndex: (unsigned)index
{
  return [self substringWithRange: ((NSRange){0,index})];;
}

- (NSString*) substringFromRange: (NSRange)aRange
{
  return [self substringWithRange: aRange];
}

- (NSString*) substringWithRange: (NSRange)aRange
{
  unichar	*buf;
  id		ret;
  unsigned	len = [self length];

  GS_RANGE_CHECK(aRange, len);

  if (aRange.length == 0)
    return @"";
  buf = NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*aRange.length);
  [self getCharacters: buf range: aRange];
  ret = [[NSStringClass allocWithZone: NSDefaultMallocZone()]
    initWithCharactersNoCopy: buf length: aRange.length freeWhenDone: YES];
  return AUTORELEASE(ret);
}

// Finding Ranges of Characters and Substrings

- (NSRange) rangeOfCharacterFromSet: (NSCharacterSet*)aSet
{
  NSRange all = NSMakeRange(0, [self length]);

  return [self rangeOfCharacterFromSet: aSet
			       options: 0
				 range: all];
}

- (NSRange) rangeOfCharacterFromSet: (NSCharacterSet*)aSet
			    options: (unsigned)mask
{
  NSRange all = NSMakeRange(0, [self length]);

  return [self rangeOfCharacterFromSet: aSet
			       options: mask
				 range: all];
}

/* xxx FIXME */
- (NSRange) rangeOfCharacterFromSet: (NSCharacterSet*)aSet
			    options: (unsigned)mask
			      range: (NSRange)aRange
{
  int		i;
  int		start;
  int		stop;
  int		step;
  NSRange	range;
  unichar	(*cImp)(id, SEL, unsigned);
  BOOL		(*mImp)(id, SEL, unichar);

  i = [self length];
  GS_RANGE_CHECK(aRange, i);

  if ((mask & NSBackwardsSearch) == NSBackwardsSearch)
    {
      start = NSMaxRange(aRange)-1; stop = aRange.location-1; step = -1;
    }
  else
    {
      start = aRange.location; stop = NSMaxRange(aRange); step = 1;
    }
  range.location = 0;
  range.length = 0;

  cImp = (unichar(*)(id,SEL,unsigned)) [self methodForSelector: caiSel];
  mImp = (BOOL(*)(id,SEL,unichar))
    [aSet methodForSelector: cMemberSel];

  for (i = start; i != stop; i += step)
    {
      unichar letter = (unichar)(*cImp)(self, caiSel, i);

      if ((*mImp)(aSet, cMemberSel, letter))
	{
	  range = NSMakeRange(i, 1);
	  break;
	}
    }

  return range;
}

- (NSRange) rangeOfString: (NSString*)string
{
  NSRange	all = NSMakeRange(0, [self length]);

  return [self rangeOfString: string
		     options: 0
		       range: all];
}

- (NSRange) rangeOfString: (NSString*)string
		  options: (unsigned)mask
{
  NSRange	all = NSMakeRange(0, [self length]);

  return [self rangeOfString: string
		     options: mask
		       range: all];
}

- (NSRange) rangeOfString: (NSString *) aString
		  options: (unsigned) mask
		    range: (NSRange) aRange
{
  if (aString == nil)
    [NSException raise: NSInvalidArgumentException format: @"range of nil"];
  return strRangeNsNs(self, aString, mask, aRange);
}

- (unsigned int) indexOfString: (NSString *)substring
{
  NSRange range = {0, [self length]};

  range = [self rangeOfString: substring options: 0 range: range];
  return range.length ? range.location : NSNotFound;
}

- (unsigned int) indexOfString: (NSString*)substring fromIndex: (unsigned)index
{
  NSRange range = {index, [self length] - index};

  range = [self rangeOfString: substring options: 0 range: range];
  return range.length ? range.location : NSNotFound;
}

// Determining Composed Character Sequences

- (NSRange) rangeOfComposedCharacterSequenceAtIndex: (unsigned)anIndex
{
  unsigned	start;
  unsigned	end;
  unsigned	length = [self length];
  unichar	ch;
  unichar	(*caiImp)(NSString*, SEL, unsigned);
  NSCharacterSet *nbSet = [NSCharacterSet nonBaseCharacterSet];

  if (anIndex >= length)
    [NSException raise: NSRangeException format:@"Invalid location."];
  caiImp = (unichar (*)())[self methodForSelector: caiSel];

  for (start = anIndex; start > 0; start--)
    {
      ch = (*caiImp)(self, caiSel, start);
      if ([nbSet characterIsMember: ch] == NO)
        break;
    }
  for (end = start+1; end < length; end++)
    {
      ch = (*caiImp)(self, caiSel, end);
      if ([nbSet characterIsMember: ch] == NO)
        break;
    }

  return NSMakeRange(start, end-start);
}

// Identifying and Comparing Strings

- (NSComparisonResult) compare: (NSString*)aString
{
  return [self compare: aString options: 0];
}

- (NSComparisonResult) compare: (NSString*)aString	
		       options: (unsigned)mask
{
  return [self compare: aString options: mask 
		 range: ((NSRange){0, [self length]})];
}

// xxx Should implement full POSIX.2 collate
- (NSComparisonResult) compare: (NSString*)aString
		       options: (unsigned)mask
			 range: (NSRange)aRange
{
  if (aString == nil)
    [NSException raise: NSInvalidArgumentException format: @"compare with nil"];
  return strCompNsNs(self, aString, mask, aRange);
}

- (BOOL) hasPrefix: (NSString*)aString
{
  NSRange	range;

  range = [self rangeOfString: aString options: NSAnchoredSearch];
  return (range.length > 0) ? YES : NO;
}

- (BOOL) hasSuffix: (NSString*)aString
{
  NSRange	range;

  range = [self rangeOfString: aString
                      options: NSAnchoredSearch | NSBackwardsSearch];
  return (range.length > 0) ? YES : NO;
}

- (BOOL) isEqual: (id)anObject
{
  if (anObject == self)
    {
      return YES;
    }
  if (anObject != nil && GSObjCIsInstance(anObject) == YES)
    {
      Class c = GSObjCClass(anObject);

      if (c != nil)
	{
	  if (GSObjCIsKindOf(c, NSStringClass))
	    {
	      return [self isEqualToString: anObject];
	    }
	}
    }
  return NO;
}

- (BOOL) isEqualToString: (NSString*)aString
{
  if ([self hash] != [aString hash])
    return NO;
  if (strCompNsNs(self, aString, 0, (NSRange){0, [self length]})
    == NSOrderedSame)
    return YES;
  return NO;
}

/*
 * Return 28-bit hash value (in 32-bit integer).  The top few bits are used
 * for other purposes in a bitfield in the concrete string subclasses, so we
 * must not use the full unsigned integer.
 */
- (unsigned) hash
{
  unsigned ret = 0;

  int len = [self length];

  if (len > NSHashStringLength)
    {
      len = NSHashStringLength;
    }
  if (len > 0)
    {
      unichar		buf[len * MAXDEC + 1];
      GSeqStruct	s = { buf, len, len * MAXDEC, 0 };
      unichar		*p;
      unsigned		char_count = 0;

      [self getCharacters: buf range: NSMakeRange(0,len)];
      GSeq_normalize(&s);

      p = buf;

      while (*p && char_count++ < NSHashStringLength)
	{
	  ret = (ret << 5) + ret + *p++;
	}

      /*
       * The hash caching in our concrete string classes uses zero to denote
       * an empty cache value, so we MUST NOT return a hash of zero.
       */
      if (ret == 0)
	ret = 0x0fffffff;
      else
	ret &= 0x0fffffff;
      return ret;
    }
  else
    return 0x0ffffffe;	/* Hash for an empty string.	*/
}

// Getting a Shared Prefix

- (NSString*) commonPrefixWithString: (NSString*)aString
			     options: (unsigned)mask
{
  if (mask & NSLiteralSearch)
    {
      int prefix_len = 0;
      unichar *u,*w;
      unichar a1[[self length]+1];
      unichar *s1 = a1;
      unichar a2[[aString length]+1];
      unichar *s2 = a2;

      u = s1;
      [self getCharacters: s1];
      s1[[self length]] = (unichar)0;
      [aString getCharacters: s2];
      s2[[aString length]] = (unichar)0;
      u = s1;
      w = s2;

      if (mask & NSCaseInsensitiveSearch)
	{
	  while (*s1 && *s2 && (uni_tolower(*s1) == uni_tolower(*s2)))
	    {
	      s1++;
	      s2++;
	      prefix_len++;
	    }
	}
      else
	{
	  while (*s1 && *s2 && (*s1 == *s2))	     
	    {
	      s1++;
	      s2++;
	      prefix_len++;
	    }
	}
      return [NSStringClass stringWithCharacters: u length: prefix_len];
    }
  else
    {
      unichar	(*scImp)(NSString*, SEL, unsigned);
      unichar	(*ocImp)(NSString*, SEL, unsigned);
      void	(*sgImp)(NSString*, SEL, unichar*, NSRange) = 0;
      void	(*ogImp)(NSString*, SEL, unichar*, NSRange) = 0;
      NSRange	(*srImp)(NSString*, SEL, unsigned) = 0;
      NSRange	(*orImp)(NSString*, SEL, unsigned) = 0;
      BOOL	gotRangeImps = NO;
      BOOL	gotFetchImps = NO;
      NSRange	sRange;
      NSRange	oRange;
      unsigned	sLength = [self length];
      unsigned	oLength = [aString length];
      unsigned	sIndex = 0;
      unsigned	oIndex = 0;

      if (!sLength)
	return self;
      if (!oLength)
	return aString;

      scImp = (unichar (*)())[self methodForSelector: caiSel];
      ocImp = (unichar (*)())[aString methodForSelector: caiSel];

      while ((sIndex < sLength) && (oIndex < oLength))
	{
	  unichar	sc = (*scImp)(self, caiSel, sIndex);
	  unichar	oc = (*ocImp)(aString, caiSel, oIndex);

	  if (sc == oc)
	    {
	      sIndex++;
	      oIndex++;
	    }
	  else if ((mask & NSCaseInsensitiveSearch)
	    && (uni_tolower(sc) == uni_tolower(oc)))
	    {
	      sIndex++;
	      oIndex++;
	    }
	  else
	    {
	      if (gotRangeImps == NO)
		{
		  gotRangeImps = YES;
		  srImp=(NSRange (*)())[self methodForSelector: ranSel];
		  orImp=(NSRange (*)())[aString methodForSelector: ranSel];
		}
	      sRange = (*srImp)(self, ranSel, sIndex);
	      oRange = (*orImp)(aString, ranSel, oIndex);

	      if ((sRange.length < 2) || (oRange.length < 2))
		return [self substringWithRange: NSMakeRange(0, sIndex)];
	      else
		{
		  GSEQ_MAKE(sBuf, sSeq, sRange.length);
		  GSEQ_MAKE(oBuf, oSeq, oRange.length);

		  if (gotFetchImps == NO)
		    {
		      gotFetchImps = YES;
		      sgImp=(void (*)())[self methodForSelector: gcrSel];
		      ogImp=(void (*)())[aString methodForSelector: gcrSel];
		    }
		  (*sgImp)(self, gcrSel, sBuf, sRange);
		  (*ogImp)(aString, gcrSel, oBuf, oRange);

		  if (GSeq_compare(&sSeq, &oSeq) == NSOrderedSame)
		    {
		      sIndex += sRange.length;
		      oIndex += oRange.length;
		    }
		  else if (mask & NSCaseInsensitiveSearch)
		    {
		      GSeq_lowercase(&sSeq);
		      GSeq_lowercase(&oSeq);
		      if (GSeq_compare(&sSeq, &oSeq) == NSOrderedSame)
			{
			  sIndex += sRange.length;
			  oIndex += oRange.length;
			}
		      else
			return [self substringWithRange: NSMakeRange(0,sIndex)];
		    }
		  else
		    return [self substringWithRange: NSMakeRange(0,sIndex)];
		}
	    }
	}
      return [self substringWithRange: NSMakeRange(0, sIndex)];
    }
}

- (NSRange) lineRangeForRange: (NSRange)aRange
{
  unsigned startIndex;
  unsigned lineEndIndex;

  [self getLineStart: &startIndex
                 end: &lineEndIndex
         contentsEnd: NULL
            forRange: aRange];
  return NSMakeRange(startIndex, lineEndIndex - startIndex);
}

- (void) getLineStart: (unsigned *)startIndex
                  end: (unsigned *)lineEndIndex
          contentsEnd: (unsigned *)contentsEndIndex
	     forRange: (NSRange)aRange
{
  unichar	thischar;
  unsigned	start, end, len;
  unichar	(*caiImp)(NSString*, SEL, unsigned);

  len = [self length];
  GS_RANGE_CHECK(aRange, len);

  caiImp = (unichar (*)())[self methodForSelector: caiSel];
  start = aRange.location;

  if (startIndex)
    {
      if (start == 0)
	{
	  *startIndex = 0;
	}
      else
	{
	  start--;
	  while (start > 0)
	    {
	      BOOL	done = NO;

	      thischar = (*caiImp)(self, caiSel, start);
	      switch (thischar)
		{
		  case (unichar)0x000A: 
		  case (unichar)0x000D: 
		  case (unichar)0x2028: 
		  case (unichar)0x2029: 
		    done = YES;
		    break;
		  default: 
		    start--;
		    break;
		}
	      if (done)
		break;
	    }
	  if (start == 0)
	    {
	       thischar = (*caiImp)(self, caiSel, start);
	       switch (thischar)
		 {
		   case (unichar)0x000A: 
		   case (unichar)0x000D: 
		   case (unichar)0x2028: 
		   case (unichar)0x2029: 
		     start++;
		     break;
		   default: 
		     break;
		 }
	    }
	  else
	    start++;
	  *startIndex = start;
	}
    }

  if (lineEndIndex || contentsEndIndex)
    {
      end = aRange.location + aRange.length;
      while (end < len)
	{
	   BOOL done = NO;

	   thischar = (*caiImp)(self, caiSel, end);
	   switch (thischar)
	     {
	       case (unichar)0x000A: 
	       case (unichar)0x000D: 
	       case (unichar)0x2028: 
	       case (unichar)0x2029: 
		 done = YES;
		 break;
	       default: 
		 break;
	     }
	   end++;
	   if (done)
	     break;
	}
      if (end < len)
	{
	  if ((*caiImp)(self, caiSel, end) == (unichar)0x000D)
	    {
	      if ((*caiImp)(self, caiSel, end+1) == (unichar)0x000A)
		*lineEndIndex = end+1;
	      else
		*lineEndIndex = end;
	    }
	  else
	    *lineEndIndex = end;
	}
      else
	*lineEndIndex = end;
    }

  if (contentsEndIndex)
    {
      if (end < len)
	{
	  *contentsEndIndex = end-1;
	}
      else
	{
	  /* xxx OPENSTEP documentation does not say what to do if last
	     line is not terminated. Assume this */
	  *contentsEndIndex = end;
	}
    }
}

// Changing Case

// xxx There is more than this in word capitalization in Unicode,
// but this will work in most cases
- (NSString*) capitalizedString
{
  unichar	*s;
  unsigned	count = 0;
  BOOL		found = YES;
  unsigned	len = [self length];

  if (len == 0)
    return self;
  if (whitespaceBitmapRep == NULL)
    setupWhitespace();

  s = NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*len);
  [self getCharacters: s];
  while (count < len)
    {
      if (GS_IS_WHITESPACE(s[count]))
	{
	  count++;
	  found = YES;
	  while (count < len
	    && GS_IS_WHITESPACE(s[count]))
	    {
	      count++;
	    }
	}
      if (count < len)
	{
	  if (found)
	    {
	      s[count] = uni_toupper(s[count]);
	      count++;
	    }
	  else
	    {
	      while (count < len
		&& !GS_IS_WHITESPACE(s[count]))
		{
		  s[count] = uni_tolower(s[count]);
		  count++;
		}
	    }
	}
      found = NO;
    }
  return AUTORELEASE([[NSString allocWithZone: NSDefaultMallocZone()]
    initWithCharactersNoCopy: s length: len freeWhenDone: YES]);
}

- (NSString*) lowercaseString
{
  unichar	*s;
  unsigned	count;
  unsigned	len = [self length];
  unichar	(*caiImp)(NSString*, SEL, unsigned);

  if (len == 0)
    {
      return self;
    }

  s = NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*len);
  caiImp = (unichar (*)())[self methodForSelector: caiSel];
  for (count = 0; count < len; count++)
    {
      s[count] = uni_tolower((*caiImp)(self, caiSel, count));
    }
  return AUTORELEASE([[NSStringClass allocWithZone: NSDefaultMallocZone()]
    initWithCharactersNoCopy: s length: len freeWhenDone: YES]);
}

- (NSString*) uppercaseString;
{
  unichar	*s;
  unsigned	count;
  unsigned	len = [self length];
  unichar	(*caiImp)(NSString*, SEL, unsigned);

  if (len == 0)
    {
      return self;
    }
  s = NSZoneMalloc(GSObjCZone(self), sizeof(unichar)*len);
  caiImp = (unichar (*)())[self methodForSelector: caiSel];
  for (count = 0; count < len; count++)
    {
      s[count] = uni_toupper((*caiImp)(self, caiSel, count));
    }
  return AUTORELEASE([[NSStringClass allocWithZone: NSDefaultMallocZone()]
    initWithCharactersNoCopy: s length: len freeWhenDone: YES]);
}

// Storing the String

- (NSString*) description
{
  return self;
}


// Getting C Strings

- (const char*) cString
{
  NSData	*d;
  NSMutableData	*m;

  d = [self dataUsingEncoding: _DefaultStringEncoding
	 allowLossyConversion: NO];
  if (d == nil)
    {
      [NSException raise: NSCharacterConversionException
		  format: @"unable to convert to cString"];
    }
  m = [d mutableCopy];
  [m appendBytes: "" length: 1];
  AUTORELEASE(m);
  return (const char*)[m bytes];
}

- (const char*) lossyCString
{
  NSData	*d;
  NSMutableData	*m;

  d = [self dataUsingEncoding: _DefaultStringEncoding
         allowLossyConversion: YES];
  m = [d mutableCopy];
  [m appendBytes: "" length: 1];
  AUTORELEASE(m);
  return (const char*)[m bytes];
}

- (const char *) UTF8String
{
  NSData	*d;
  NSMutableData	*m;

  d = [self dataUsingEncoding: NSUTF8StringEncoding
         allowLossyConversion: NO];
  m = [d mutableCopy];
  [m appendBytes: "" length: 1];
  AUTORELEASE(m);
  return (const char*)[m bytes];
}

- (unsigned) cStringLength
{
  NSData	*d;

  d = [self dataUsingEncoding: _DefaultStringEncoding
         allowLossyConversion: NO];
  return [d length];
}

- (void) getCString: (char*)buffer
{
  [self getCString: buffer maxLength: NSMaximumStringLength
	     range: ((NSRange){0, [self length]})
    remainingRange: NULL];
}

- (void) getCString: (char*)buffer
	  maxLength: (unsigned)maxLength
{
  [self getCString: buffer maxLength: maxLength 
	     range: ((NSRange){0, [self length]})
    remainingRange: NULL];
}

- (void) getCString: (char*)buffer
	  maxLength: (unsigned)maxLength
	      range: (NSRange)aRange
     remainingRange: (NSRange*)leftoverRange
{
  unsigned	len;
  unsigned	count;
  unichar	(*caiImp)(NSString*, SEL, unsigned);

  len = [self cStringLength];
  GS_RANGE_CHECK(aRange, len);

  caiImp = (unichar (*)())[self methodForSelector: caiSel];

  if (maxLength < aRange.length)
    {
      len = maxLength;
      if (leftoverRange)
	{
	  leftoverRange->location = 0;
	  leftoverRange->length = 0;
	}
    }
  else
    {
      len = aRange.length;
      if (leftoverRange)
	{
	  leftoverRange->location = aRange.location + maxLength;
	  leftoverRange->length = aRange.length - maxLength;
	}
    }
  count = 0;
  while (count < len)
    {
      buffer[count] = encode_unitochar(
	(*caiImp)(self, caiSel, aRange.location + count),
	_DefaultStringEncoding);
      if (buffer[count] == 0)
	{
	  [NSException raise: NSCharacterConversionException
		      format: @"unable to convert to cString"];
	}
      count++;
    }
  buffer[len] = '\0';
}


// Getting Numeric Values

// xxx Sould we use NSScanner here ?

- (BOOL) boolValue
{
  if ([self caseInsensitiveCompare: @"YES"] == NSOrderedSame) 
    return YES;
  return [self intValue] != 0 ? YES : NO;
}

- (double) doubleValue
{
  return atof([self lossyCString]);
}

- (float) floatValue
{
  return (float) atof([self lossyCString]);
}

- (int) intValue
{
  return atoi([self lossyCString]);
}

// Working With Encodings

+ (NSStringEncoding) defaultCStringEncoding
{
  return _DefaultStringEncoding;
}

+ (NSStringEncoding*) availableStringEncodings
{
  return GetAvailableEncodings();
}

+ (NSString*) localizedNameOfStringEncoding: (NSStringEncoding)encoding
{
  id ourbundle;
  id ourname;

/*
      Should be path to localizable.strings file.
      Until we have it, just make sure that bundle
      is initialized.
*/
  ourbundle = [NSBundle gnustepBundle];

  ourname = GetEncodingName(encoding);
  return [ourbundle localizedStringForKey: ourname
				    value: ourname
				    table: nil];
}

- (BOOL) canBeConvertedToEncoding: (NSStringEncoding)encoding
{
  id d = [self dataUsingEncoding: encoding allowLossyConversion: NO];

  return d != nil ? YES : NO;
}

- (NSData*) dataUsingEncoding: (NSStringEncoding)encoding
{
  return [self dataUsingEncoding: encoding allowLossyConversion: NO];
}

- (NSData*) dataUsingEncoding: (NSStringEncoding)encoding
	 allowLossyConversion: (BOOL)flag
{
  unsigned int	count = 0;
  unsigned int	len = [self length];
  unichar	(*caiImp)(NSString*, SEL, unsigned);

  if (len == 0)
    {
      return [NSDataClass data];
    }

  caiImp = (unichar (*)())[self methodForSelector: caiSel];
  if ((encoding == NSASCIIStringEncoding)
    || (encoding == NSISOLatin1StringEncoding)
    || (encoding == NSISOLatin2StringEncoding)
    || (encoding == NSNEXTSTEPStringEncoding)
    || (encoding == NSNonLossyASCIIStringEncoding)
    || (encoding == NSSymbolStringEncoding)
    || (encoding == NSISOCyrillicStringEncoding))
    {
      char		t;
      unsigned char	*buff;

      buff = (unsigned char*)NSZoneMalloc(NSDefaultMallocZone(), len+1);
      if (!flag)
	{
	  for (count = 0; count < len; count++)
	    {
	      t = encode_unitochar((*caiImp)(self, caiSel, count), encoding);
	      if (t)
		{
		  buff[count] = t;
		}
	      else
		{
		  NSZoneFree(NSDefaultMallocZone(), buff);
		  return nil;
		}
	    }
	}
      else /* lossy */
	{
	  for (count = 0; count < len; count++)
	    {
	      t = encode_unitochar((*caiImp)(self, caiSel, count), encoding);
	      if (t)
		{
		  buff[count] = t;
		}
	      else
		{
		  /* xxx should handle decomposed characters */
		  /* OpenStep documentation is unclear on what to do
		   * if there is no simple replacement for character
		   */
		  buff[count] = '*';
		}
	    }
	}
      buff[count] = '\0';
      return [NSDataClass dataWithBytesNoCopy: buff length: count];
    }
  else if (encoding == NSUTF8StringEncoding)
    {
      unsigned char	*buff;
      unsigned		i, j;
      unichar		ch, ch2;
      gsu32		cp;

      buff = (unsigned char *)NSZoneMalloc(NSDefaultMallocZone(), len*3);

      /*
       * Each UTF-16 character maps to at most 3 bytes of UTF-8, so we simply
       * allocate three times as many bytes as UTF-16 characters, then use
       * NSZoneRealloc() later to trim the excess.  Most Unix virtual memory
       * implementations allocate address space, and actual memory pages are
       * not actually allocated until used, so this method shouldn't cause
       * memory problems on most Unix systems.  On other systems, it may prove
       * advantageous to scan the UTF-16 string to determine the UTF-8 string
       * length before allocating memory.
       */
      for (i = j = 0; i < len; i++)
        {
          ch = (*caiImp)(self, caiSel, i);
          if (NSLocationInRange(ch, highSurrogateRange) && ((i+1) < len))
            {
              ch2 = (*caiImp)(self, caiSel, i+1);
              if (NSLocationInRange(ch2, lowSurrogateRange))
                {
                  cp = surrogatePairValue(ch, ch2);
                  i++;
                }
              else
                cp = (gsu32)ch;
            }
          else
            cp = (gsu32)ch;

          if (cp < 0x80)
            {
              buff[j++] = cp;
            }
          else if (cp < 0x800)
            {
              buff[j++] = 0xC0 | ch>>6;
              buff[j++] = 0x80 | (ch & 0x3F);
            }
          else if (cp < 0x10000)
            {
              buff[j++] = 0xE0 | ch>>12;
              buff[j++] = 0x80 | (ch>>6 & 0x3F);
              buff[j++] = 0x80 | (ch & 0x3F);
            }
          else if (cp < 0x200000)
            {
              buff[j++] = 0xF0 | ch>>18;
              buff[j++] = 0x80 | (ch>>12 & 0x3F);
              buff[j++] = 0x80 | (ch>>6 & 0x3F);
              buff[j++] = 0x80 | (ch & 0x3F);
            }
        }

      NSZoneRealloc(NSDefaultMallocZone(), buff, j);

      return [NSDataClass dataWithBytesNoCopy: buff
                                       length: count];
    }
  else if (encoding == NSUnicodeStringEncoding)
    {
      unichar	*buff;

      buff = (unichar*)NSZoneMalloc(NSDefaultMallocZone(),
	sizeof(unichar)*(len+1));
      buff[0] = 0xFEFF;
      for (count = 0; count < len; count++)
	{
	  buff[count+1] = (*caiImp)(self, caiSel, count);
	}
      return [NSDataClass dataWithBytesNoCopy: buff
					length: sizeof(unichar)*(len+1)];
    }
  else
    {
      int		t;
      unichar		*u;
      unsigned char	*buff;

      u = (unichar*)NSZoneMalloc(NSDefaultMallocZone(), len*sizeof(unichar));
      [self getCharacters: u];
      buff = (unsigned char*)NSZoneMalloc(NSDefaultMallocZone(), len);
      if (flag == YES)
	t = encode_ustrtostr(buff, u, len, encoding);
      else 
	t = encode_ustrtostr_strict(buff, u, len, encoding);
      NSZoneFree(NSDefaultMallocZone(), u);
      if (t == 0)
        {
	  NSZoneFree(NSDefaultMallocZone(), buff);
	  return nil;
	}
      return [NSDataClass dataWithBytesNoCopy: buff length: t];
    }
  return nil;
}

- (NSStringEncoding) fastestEncoding
{
  return NSUnicodeStringEncoding;
}

- (NSStringEncoding) smallestEncoding
{
  return NSUnicodeStringEncoding;
}


// Manipulating File System Paths

- (unsigned) completePathIntoString: (NSString**)outputName
		      caseSensitive: (BOOL)flag
		   matchesIntoArray: (NSArray**)outputArray
			filterTypes: (NSArray*)filterTypes
{
  NSString	*base_path = [self stringByDeletingLastPathComponent];
  NSString	*last_compo = [self lastPathComponent];
  NSString	*tmp_path;
  NSDirectoryEnumerator *e;
  NSMutableArray	*op = nil;
  unsigned	match_count = 0;

  if (outputArray != 0)
    op = (NSMutableArray*)[NSMutableArray array];

  if (outputName != NULL)
    *outputName = nil;

  if ([base_path length] == 0)
    base_path = @".";

  e = [[NSFileManager defaultManager] enumeratorAtPath: base_path];
  while (tmp_path = [e nextObject], tmp_path)
    {
      /* Prefix matching */
      if (YES == flag)
	{ /* Case sensitive */
	  if (NO == [tmp_path hasPrefix: last_compo])
	    continue ;
	}
      else
	{
	  if (NO == [[tmp_path uppercaseString]
		      hasPrefix: [last_compo uppercaseString]])
	    continue;
	}

      /* Extensions filtering */
      if (filterTypes &&
	  (NO == [filterTypes containsObject: [tmp_path pathExtension]]))
	continue ;

      /* Found a completion */
      match_count++;
      if (outputArray != NULL)
	[*op addObject: tmp_path];
      
      if ((outputName != NULL) && 
	((*outputName == nil) || (([*outputName length] < [tmp_path length]))))
	*outputName = tmp_path;
    }
  if (outputArray != NULL)
    *outputArray = AUTORELEASE([op copy]);
  return match_count;
}

/* Return a string for passing to OS calls to handle file system objects. */
- (const char*) fileSystemRepresentation
{
  static NSFileManager *fm = nil;

  if (fm == nil)
    {
      fm = [NSFileManager defaultManager];
    }
  
  return [fm fileSystemRepresentationWithPath: self];
}

- (BOOL) getFileSystemRepresentation: (char*)buffer maxLength: (unsigned)size
{
  const char* ptr = [self fileSystemRepresentation];
  if (strlen(ptr) > size)
    return NO;
  strcpy(buffer, ptr);
  return YES;
}

/* Returns a new string containing the last path component of the receiver. The
   path component is any substring after the last '/' character. If the last
   character is a '/', then the substring before the last '/', but after the
   second-to-last '/' is returned. Returns the receiver if there are no '/'
   characters. Returns the null string if the receiver only contains a '/'
   character. */
- (NSString*) lastPathComponent
{
  NSRange range;
  NSString *substring = nil;

  range = [self rangeOfCharacterFromSet: pathSeps() options: NSBackwardsSearch];
  if (range.length == 0)
    substring = AUTORELEASE([self copy]);
  else if (range.location == ([self length] - 1))
    {
      if (range.location == 0)
	substring = @"";
      else
	substring = [[self substringToIndex: range.location] 
		      lastPathComponent];
    }
  else
    substring = [self substringFromIndex: range.location + 1];

  return substring;
}

/* Returns a new string containing the path extension of the receiver. The
   path extension is a suffix on the last path component which starts with
   a '.' (for example .tiff is the pathExtension for /foo/bar.tiff). Returns
   a null string if no such extension exists. */
- (NSString*) pathExtension
{
  NSRange range;
  NSString *substring = nil;

  range = [self rangeOfString: @"." options: NSBackwardsSearch];
  if (range.length == 0) 
    substring = nil;
  else
    {
      NSRange range2 = [self rangeOfCharacterFromSet: pathSeps()
					     options: NSBackwardsSearch];
      if (range2.length > 0 && range.location < range2.location)
	substring = nil;
      else
	substring = [self substringFromIndex: range.location + 1];
    }

  if (!substring)
    substring = @"";
  return substring;
}

/* Returns a new string with the path component given in aString
 * appended to the receiver.
 * Removes trailing separators and multiple separators.
 */
- (NSString*) stringByAppendingPathComponent: (NSString*)aString
{
  unsigned	length = [self length];
  unsigned	aLength = [aString length];
  unichar	buf[length+aLength+1];

  [self getCharacters: buf];
  if (aLength > 0)
    {
      if (length > 0)
	{
	  buf[length++] = pathSepChar;
	}
      [aString getCharacters: &buf[length]];
    }
  length += aLength;
  while (length > 1 && pathSepMember(buf[length-1]) == YES)
    {
      length--;
    }
  if (length > 0)
    {
#if defined(__MINGW__)
#define _PATH_SEARCH_END 1
#else
#define _PATH_SEARCH_END 0
#endif
      aLength = length - 1;
      while (aLength > _PATH_SEARCH_END)
#undef _PATH_SEARCH_END
	{
	  if (pathSepMember(buf[aLength]) == YES)
	    {
	      if (pathSepMember(buf[aLength-1]) == YES)
		{
		  unsigned	pos;

		  for (pos = aLength+1; pos < length; pos++)
		    {
		      buf[pos-1] = buf[pos];
		    }
		  length--;
		}
	    }
	  aLength--;
	}
    }
  return [NSStringClass stringWithCharacters: buf length: length];
}

/* Returns a new string with the path extension given in aString
   appended to the receiver.
   A '.' is appended before appending aString */
- (NSString*) stringByAppendingPathExtension: (NSString*)aString
{
  if ([aString length] == 0)
    return [self stringByAppendingString: @"."];
  else
    return [self stringByAppendingFormat: @".%@", aString];
}

/* Returns a new string with the last path component removed from the
  receiver.  See lastPathComponent for a definition of a path component */
- (NSString*) stringByDeletingLastPathComponent
{
  NSRange range;
  NSString *substring;

  range = [self rangeOfString: [self lastPathComponent] 
		      options: NSBackwardsSearch];

  if (range.length == 0)
    substring = AUTORELEASE([self copy]);
  else if (range.location == 0)
    substring = @"";
  else if (range.location > 1)
    substring = [self substringToIndex: range.location-1];
  else
    substring = pathSepString;
  return substring;
}

/*
 * Returns a new string with the path extension removed from the receiver.
 * Strips any trailing path separators before checking for the extension
 * separator.
 */
- (NSString*) stringByDeletingPathExtension
{
  NSRange	range;
  NSRange	r0;
  NSRange	r1;
  NSString	*substring;
  unsigned	length = [self length];

  /*
   * Skip past any trailing path separators... but not a leading one.
   */
  while (length > 1 && pathSepMember([self characterAtIndex: length-1]) == YES)
    {
      length--;
    }
  range = NSMakeRange(0, length);
  /*
   * Locate path extension.
   */
  r0 = [self rangeOfString: @"."
		   options: NSBackwardsSearch
		     range: range];
  /*
   * Locate a path separator.
   */
  r1 = [self rangeOfCharacterFromSet: pathSeps()
			     options: NSBackwardsSearch
			       range: range];
  /*
   * Assuming the extension separator was found in the last path
   * component, set the length of the substring we want.
   */
  if (r0.length > 0 && (r1.length == 0 || r1.location < r0.location))
    {
      length = r0.location;
    }
  substring = [self substringToIndex: length];
  return substring;
}

- (NSString*) stringByExpandingTildeInPath
{
  NSString	*homedir;
  NSRange	first_slash_range;
  
  if ([self length] == 0)
    return AUTORELEASE([self copy]);
  if ([self characterAtIndex: 0] != 0x007E)
    return AUTORELEASE([self copy]);

  first_slash_range = [self rangeOfString: pathSepString];

  if (first_slash_range.location != 1)
    {
      /* It is of the form `~username/blah/...' */
      int	uname_len;
      NSString	*uname;

      if (first_slash_range.length != 0)
	{
	  uname_len = first_slash_range.length - 1;
	}
      else
	{
	  /* It is actually of the form `~username' */
	  uname_len = [self length] - 1;
	  first_slash_range.location = [self length];
	}
      uname = [self substringWithRange: ((NSRange){1, uname_len})];
      homedir = NSHomeDirectoryForUser (uname);
    }
  else
    {
      /* It is of the form `~/blah/...' */
      homedir = NSHomeDirectory ();
    }
  
  return [NSStringClass stringWithFormat: @"%@%@", homedir, 
    [self substringFromIndex: first_slash_range.location]];
}

- (NSString*) stringByAbbreviatingWithTildeInPath
{
  NSString *homedir = NSHomeDirectory ();

  if (![self hasPrefix: homedir])
    return AUTORELEASE([self copy]);

  return [NSStringClass stringWithFormat: @"~%c%@", (char)pathSepChar,
    [self substringFromIndex: [homedir length] + 1]];
}

- (NSString*) stringByResolvingSymlinksInPath
{
#if defined(__MINGW__)
  return self;
#else 
  #ifndef MAX_PATH
  #define MAX_PATH 1024
  #endif
  char		new_buf[MAX_PATH];
#if HAVE_REALPATH

  if (realpath([self cString], new_buf) == 0)
    return self;
#else
  char		extra[MAX_PATH];
  char		*dest;
  const char	*name = [self cString];
  const char	*start;
  const	char	*end;
  unsigned	num_links = 0;


  if (name[0] != '/')
    {
      if (!getcwd(new_buf, MAX_PATH))
        return self;			/* Couldn't get directory.	*/
      dest = strchr(new_buf, '\0');
    }
  else
    {
      new_buf[0] = '/';
      dest = &new_buf[1];
    }

  for (start = end = name; *start; start = end)
    {
      struct stat	st;
      int		n;
      int		len;

      /* Elide repeated path separators	*/
      while (*start == '/')
	start++;

      /* Locate end of path component	*/
      end = start;
      while (*end && *end != '/')
	end++;

      len = end - start;
      if (len == 0)
	{
	  break;	/* End of path.	*/
	}
      else if (len == 1 && *start == '.')
	{
          /* Elide '/./' sequence by ignoring it.	*/
	}
      else if (len == 2 && strncmp(start, "..", len) == 0)
	{
	  /*
	   * Backup - if we are not at the root, remove the last component.
	   */
	  if (dest > &new_buf[1])
	    {
	      do
		{
		  dest--;
		}
	      while (dest[-1] != '/');
	    }
	}
      else
        {
          if (dest[-1] != '/')
            *dest++ = '/';

          if (&dest[len] >= &new_buf[MAX_PATH])
	    return self;	/* Resolved name would be too long.	*/

          memcpy(dest, start, len);
          dest += len;
          *dest = '\0';

          if (lstat(new_buf, &st) < 0)
            return self;	/* Unable to stat file.		*/

          if (S_ISLNK(st.st_mode))
            {
              char buf[MAX_PATH];

              if (++num_links > MAXSYMLINKS)
		return self;	/* Too many symbolic links.	*/

              n = readlink(new_buf, buf, MAX_PATH);
              if (n < 0)
		return self;	/* Couldn't resolve links.	*/

              buf[n] = '\0';

              if ((n + strlen(end)) >= MAX_PATH)
		return self;	/* Path would be too long.	*/

	      /*
	       * Concatenate the resolved name with the string still to
	       * be processed, and start using the result as input.
	       */
              strcat(buf, end);
              strcpy(extra, buf);
              name = end = extra;

              if (buf[0] == '/')
		{
		  /*
		   * For an absolute link, we start at root again.
		   */
		  dest = new_buf + 1;
		}
              else
		{
		  /*
		   * Backup - remove the last component.
		   */
		  if (dest > new_buf + 1)
		    {
		      do
			{
			  dest--;
			}
		      while (dest[-1] != '/');
		    }
		}
            }
          else
	    {
	      num_links = 0;
	    }
        }
    }
  if (dest > new_buf + 1 && dest[-1] == '/')
    --dest;
  *dest = '\0';
#endif
  if (strncmp(new_buf, "/private/", 9) == 0)
    {
      struct stat	st;

      if (lstat(&new_buf[8], &st) == 0)
	strcpy(new_buf, &new_buf[8]);
    }
  return [NSStringClass stringWithCString: new_buf];
#endif  /* (__MINGW__) */  
}

- (NSString*) stringByStandardizingPath
{
  NSMutableString	*s;
  NSRange		r;
  unichar		(*caiImp)(NSString*, SEL, unsigned);

  /* Expand `~' in the path */
  s = [[self stringByExpandingTildeInPath] mutableCopy];
  caiImp = (unichar (*)())[s methodForSelector: caiSel];

  /* Remove `/private' */
  if ([s hasPrefix: @"/private"])
    [s deleteCharactersInRange: ((NSRange){0,7})];

  /* Condense `//' and '/./' */
  r = NSMakeRange(0, [s length]);
  while ((r = [s rangeOfCharacterFromSet: pathSeps()
				 options: 0
				   range: r]).length)
    {
      unsigned	length = [s length];

      if (r.location + r.length + 1 <= length
	&& pathSepMember((*caiImp)(s, caiSel, r.location + 1)) == YES)
	{
#if defined(__MINGW__)
	   if (r.location)
	     {
	       [s deleteCharactersInRange: r];
	     }
	   else
	     {
	       r.location++;
	     }
#else
	  [s deleteCharactersInRange: r];
#endif /* (__MINGW__) */
	}
      else if (r.location + r.length + 2 <= length
	&& (*caiImp)(s, caiSel, r.location + 1) == (unichar)'.'
	&& pathSepMember((*caiImp)(s, caiSel, r.location + 2)) == YES)
	{
	  r.length++;
	  [s deleteCharactersInRange: r];
	}
      else
	{
	  r.location++;
	}
      if ((r.length = [s length]) > r.location)
	r.length -= r.location;
      else
	break;
    }

  if ([s isAbsolutePath] == NO)
    return s;

  /*
   *	For absolute paths, we must resolve symbolic links or (on MINGW)
   *	remove '/../' sequences and their matching parent directories.
   */
#if defined(__MINGW__)
  /* Condense `/../' */
  r = NSMakeRange(0, [s length]);
  while ((r = [s rangeOfCharacterFromSet: pathSeps()
				 options: 0
				   range: r]).length)
    {
      if (r.location + r.length + 3 <= [s length]
	&& (*caiImp)(s, caiSel, r.location + 1) == (unichar)'.'
	&& (*caiImp)(s, caiSel, r.location + 2) == (unichar)'.'
	&& pathSepMember((*caiImp)(s, caiSel, r.location + 3)) == YES)
	{
	  if (r.location > 0)
	    {
	      NSRange r2 = {0, r.location};
	      r = [s rangeOfCharacterFromSet: pathSeps()
				     options: NSBackwardsSearch
				       range: r2];
	      if (r.length == 0)
		r = r2;
	      r.length += 4;		/* Add the `/../' */
	    }
	  [s deleteCharactersInRange: r];
	}
      else
	r.location++;
      if ((r.length = [s length]) > r.location)
	r.length -= r.location;
      else
	break;
    }

  return s;
#else
  return [s stringByResolvingSymlinksInPath];
#endif
}

// private methods for Unicode level 3 implementation
- (int) _baseLength
{
  int		blen = 0;
  unsigned	len = [self length];

  if (len > 0)
    {
      int	count = 0;
      unichar	(*caiImp)(NSString*, SEL, unsigned);

      caiImp = (unichar (*)())[self methodForSelector: caiSel];
      while (count < len)
	{
	  if (!uni_isnonsp((*caiImp)(self, caiSel, count++)))
	    {
	      blen++;
	    }
	}
    }
  return blen;
} 

+ (NSString*) pathWithComponents: (NSArray*)components
{
  NSString	*s;
  unsigned	c;
  unsigned	i;

  c = [components count];
  if (c == 0)
    return @"";
  s = [components objectAtIndex: 0];
  if ([s length] == 0 || [s isEqualToString: pathSepString] == YES)
    s = rootPath;
  for (i = 1; i < c; i++)
    {
      s = [s stringByAppendingPathComponent: [components objectAtIndex: i]];
    }
  return s;
}

- (BOOL) isAbsolutePath
{
  if ([self length] == 0)
    {
      return NO;
    }
#if defined(__MINGW__)
  if ([self indexOfString: @":"] == NSNotFound)
    {
      const char *cpath = [self fileSystemRepresentation];
      if (isalpha(cpath[0]) && cpath[1] == ':')
	{
	  return YES;
	}
      else if (cpath[0] == cpath[1]
	&& (cpath[0] == '/' || cpath[0] == '\\'))
	{
	  return YES;
	}
      else
	{
	  return NO;
	}
    }
  else
    {
      return YES;
    }
#else
  {
    unichar	c = [self characterAtIndex: 0];

    if (c == (unichar)'/' || c == (unichar)'~')
      {
	return YES;
      }
  }
#endif
  return NO;
}

- (NSArray*) pathComponents
{
  NSMutableArray	*a;
  NSArray		*r;

  if ([self length] == 0)
    {
      return [NSArray array];
    }
  a = [[self componentsSeparatedByString: pathSepString] mutableCopy];
  if ([a count] > 0)
    {
      int	i;

      /*
       * If the path began with a '/' then the first path component must
       * be a '/' rather than an empty string so that our output could be
       * fed into [+pathWithComponents: ]
       */
      if ([[a objectAtIndex: 0] length] == 0)
	{
	  [a replaceObjectAtIndex: 0 withObject: pathSepString];
	}
      /*
       * Similarly if the path ended with a path separator (other than the
       * leading one).
       */
      if ([[a objectAtIndex: [a count]-1] length] == 0)
	{
	  if ([self length] > 1)
	    {
	      [a replaceObjectAtIndex: [a count]-1 withObject: pathSepString];
	    }
	}
      /* Any empty path components  must be removed. */
      for (i = [a count] - 1; i > 0; i--)
	{
	  if ([[a objectAtIndex: i] length] == 0)
	    {
	      [a removeObjectAtIndex: i];
	    }
	}
    }
  r = [a copy];
  RELEASE(a);
  return AUTORELEASE(r);
}

- (NSArray*) stringsByAppendingPaths: (NSArray*)paths
{
  NSMutableArray	*a;
  NSArray		*r;
  unsigned		i, count = [paths count];

  a = [[NSMutableArray allocWithZone: NSDefaultMallocZone()]
	initWithCapacity: count];
  for (i = 0; i < count; i++)
    {
      NSString	*s = [paths objectAtIndex: i];

      while ([s isAbsolutePath])
	{
	  s = [s substringFromIndex: 1];
	}
      s = [self stringByAppendingPathComponent: s];
      [a addObject: s];
    }
  r = [a copy];
  RELEASE(a);
  return AUTORELEASE(r);
}

+ (NSString*) localizedStringWithFormat: (NSString*) format, ...
{
  va_list ap;
  id ret;
  NSDictionary *dict;

  va_start(ap, format);
  if (format == nil)
    {
      ret = nil;
    }
  else
    {
      dict = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
      ret = AUTORELEASE([[self allocWithZone: NSDefaultMallocZone()]
        initWithFormat: format locale: dict arguments: ap]);
    }
  va_end(ap);
  return ret;
}

- (NSComparisonResult) caseInsensitiveCompare: (NSString*)aString
{
  return [self compare: aString
	       options: NSCaseInsensitiveSearch 
		 range: ((NSRange){0, [self length]})];
}

- (NSComparisonResult) compare: (NSString *)string 
		       options: (unsigned)mask 
			 range: (NSRange)compareRange 
			locale: (NSDictionary *)dict
{
  // FIXME: This does only a normal compare
  return [self compare: string
	       options: mask
		 range: compareRange];
}

- (NSComparisonResult) localizedCompare: (NSString *)string
{
  NSDictionary *dict =
      [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];

  return [self compare: string
               options: 0
                 range: ((NSRange){0, [self length]})
                locale: dict];
}

- (NSComparisonResult) localizedCaseInsensitiveCompare: (NSString *)string
{
  NSDictionary *dict =
      [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];

  return [self compare: string
               options: NSCaseInsensitiveSearch 
                 range: ((NSRange){0, [self length]})
                locale: dict];
}

- (BOOL) writeToFile: (NSString*)filename
	  atomically: (BOOL)useAuxiliaryFile
{
  id	d = [self dataUsingEncoding: _DefaultStringEncoding];

  if (d == nil)
    {
      d = [self dataUsingEncoding: NSUnicodeStringEncoding];
    }
  return [d writeToFile: filename atomically: useAuxiliaryFile];
}

- (BOOL) writeToURL: (NSURL*)anURL atomically: (BOOL)atomically
{
  id	d = [self dataUsingEncoding: _DefaultStringEncoding];

  if (d == nil)
    {
      d = [self dataUsingEncoding: NSUnicodeStringEncoding];
    }
  return [d writeToURL: anURL atomically: atomically];
}

- (void) descriptionWithLocale: (NSDictionary*)aLocale
			indent: (unsigned)level
			    to: (id<GNUDescriptionDestination>)output
{
  unsigned	length;

  if ((length = [self length]) == 0)
    {
      [output appendString: @"\"\""];
      return;
    }

  if (quotablesBitmapRep == NULL)
    {
      setupQuotables();
    }
  if ([self rangeOfCharacterFromSet: quotables].length > 0)
    {
      unichar	tmp[length <= 1024 ? length : 0];
      unichar	*ustring;
      unichar	*from;
      unichar	*end;
      int	len = 0;

      if (length <= 1024)
	{
	  ustring = tmp;
	}
      else
	{
	  ustring = NSZoneMalloc(NSDefaultMallocZone(), length*sizeof(unichar));
	}
      end = &ustring[length];
      [self getCharacters: ustring];
      for (from = ustring; from < end; from++)
	{
	  switch (*from)
	    {
	      case '\a': 
	      case '\b': 
	      case '\t': 
	      case '\r': 
	      case '\n': 
	      case '\v': 
	      case '\f': 
	      case '\\': 
	      case '\'' : 
	      case '"' : 
		len += 2;
		break;

	      default: 
		if (*from < 128)
		  {
		    if (isprint(*from) || *from == ' ')
		      {
			len++;
		      }
		    else
		      {
			len += 4;
		      }
		  }
		else
		  {
		    len += 10;
		  }
		break;
	    }
	}

      {
	char	buf[len+3];
	char	*ptr = buf;

	*ptr++ = '"';
	for (from = ustring; from < end; from++)
	  {
	    switch (*from)
	      {
		case '\a': 	*ptr++ = '\\'; *ptr++ = 'a';  break;
		case '\b': 	*ptr++ = '\\'; *ptr++ = 'b';  break;
		case '\t': 	*ptr++ = '\\'; *ptr++ = 't';  break;
		case '\r': 	*ptr++ = '\\'; *ptr++ = 'r';  break;
		case '\n': 	*ptr++ = '\\'; *ptr++ = 'n';  break;
		case '\v': 	*ptr++ = '\\'; *ptr++ = 'v';  break;
		case '\f': 	*ptr++ = '\\'; *ptr++ = 'f';  break;
		case '\\': 	*ptr++ = '\\'; *ptr++ = '\\'; break;
		case '\'': 	*ptr++ = '\\'; *ptr++ = '\''; break;
		case '"' : 	*ptr++ = '\\'; *ptr++ = '"';  break;

		default: 
		  if (*from < 128)
		    {
		      if (isprint(*from) || *from == ' ')
			{
			  *ptr++ = *from;
			}
		      else
			{
			  sprintf(ptr, "\\%03o", *(unsigned char*)from);
			  ptr = &ptr[4];
			}
		    }
		  else
		    {
		      sprintf(ptr, "\\U%08x", *from);
		      ptr = &ptr[10];
		    }
		  break;
	      }
	  }
	*ptr++ = '"';
	*ptr = '\0';
	[output appendString: [NSStringClass stringWithCString: buf]];
      }
      if (length > 1024)
	{
	  NSZoneFree(NSDefaultMallocZone(), ustring);
	}
    }
  else
    {
      [output appendString: self];
    }
}


/* NSCopying Protocol */

- (id) copyWithZone: (NSZone*)zone
{
  if ([self isKindOfClass: [NSMutableString class]] ||
    NSShouldRetainWithZone(self, zone) == NO)
    return [[NSStringClass allocWithZone: zone] initWithString: self];
  else
    return RETAIN(self);
}

- (id) mutableCopyWithZone: (NSZone*)zone
{
  return [[GSMutableStringClass allocWithZone: zone] initWithString: self];
}

/* NSCoding Protocol */

- (void) encodeWithCoder: (NSCoder*)aCoder
{
  unsigned	count = [self length];

  [aCoder encodeValueOfObjCType: @encode(unsigned) at: &count];
  if (count > 0)
    {
      NSStringEncoding	enc = NSUnicodeStringEncoding;
      unichar		*chars;

      [aCoder encodeValueOfObjCType: @encode(NSStringEncoding) at: &enc];

      chars = NSZoneMalloc(NSDefaultMallocZone(), count*sizeof(unichar));
      [self getCharacters: chars];
      [aCoder encodeArrayOfObjCType: @encode(unichar)
			      count: count
				 at: chars];
      NSZoneFree(NSDefaultMallocZone(), chars);
    }
}

- (id) initWithCoder: (NSCoder*)aCoder
{
  unsigned	count;

  [aCoder decodeValueOfObjCType: @encode(unsigned) at: &count];

  if (count > 0)
    {
      NSStringEncoding	enc;
      NSZone		*zone;
  
      [aCoder decodeValueOfObjCType: @encode(NSStringEncoding) at: &enc];
#if	GS_WITH_GC
      zone = GSAtomicMallocZone();
#else
      zone = GSObjCZone(self);
#endif

      if (enc == NSUnicodeStringEncoding)
	{
	  unichar	*chars;

	  chars = NSZoneMalloc(zone, count*sizeof(unichar));
	  [aCoder decodeArrayOfObjCType: @encode(unichar)
				  count: count
				     at: chars];
	  self = [self initWithCharactersNoCopy: chars
					 length: count
				   freeWhenDone: YES];
	}
      else if (enc == NSASCIIStringEncoding
	|| enc == _DefaultStringEncoding)
	{
	  unsigned char	*chars;

	  chars = NSZoneMalloc(zone, count+1);
	  [aCoder decodeArrayOfObjCType: @encode(unsigned char)
				  count: count
				     at: chars];
	  self = [self initWithCStringNoCopy: chars
				      length: count
				freeWhenDone: YES];
	}
      else if (enc == NSUTF8StringEncoding)
	{
	  unsigned char	*chars;

	  chars = NSZoneMalloc(zone, count+1);
	  [aCoder decodeArrayOfObjCType: @encode(unsigned char)
				  count: count
				     at: chars];
	  chars[count] = '\0';
	  self = [self initWithUTF8String: chars];
	  NSZoneFree(zone, chars);
	}
      else
	{
	  unsigned char	*chars;
	  NSData	*data;

	  chars = NSZoneMalloc(zone, count);
	  [aCoder decodeArrayOfObjCType: @encode(unsigned char)
				  count: count
				     at: chars];
	  data = [NSDataClass allocWithZone: zone];
	  data = [data initWithBytesNoCopy: chars length: count];
	  self = [self initWithData: data encoding: enc];
	  RELEASE(data);
	}
    }
  else
    {
      self = [self initWithCStringNoCopy: 0 length: 0 freeWhenDone: NO];
    }
  return self;
}

- (Class) classForCoder
{
  return NSStringClass;
}

- (id) replacementObjectForPortCoder: (NSPortCoder*)aCoder
{
  if ([aCoder isByref] == NO)
    return self;
  return [super replacementObjectForPortCoder: aCoder];
}

- (id) propertyList
{
  return GSPropertyList(self);
}

- (NSDictionary*) propertyListFromStringsFileFormat
{
  return GSPropertyListFromStringsFormat(self);
}

@end


@implementation NSMutableString

+ (id) allocWithZone: (NSZone*)z
{
  if (self == NSMutableStringClass)
    {
      return NSAllocateObject(GSMutableStringClass, 0, z);
    }
  else
    {
      return NSAllocateObject(self, 0, z);
    }
}

// Creating Temporary Strings

+ (NSMutableString*) string
{
  return AUTORELEASE([[GSMutableStringClass allocWithZone:
    NSDefaultMallocZone()] initWithCapacity: 0]);
}

+ (NSMutableString*) stringWithCapacity: (unsigned)capacity
{
  return AUTORELEASE([[GSMutableStringClass allocWithZone:
    NSDefaultMallocZone()] initWithCapacity: capacity]);
}

/* Inefficient. */
+ (NSString*) stringWithCharacters: (const unichar*)characters
			    length: (unsigned)length
{
  return AUTORELEASE([[GSMutableStringClass allocWithZone:
    NSDefaultMallocZone()] initWithCharacters: characters length: length]);
}

+ (id) stringWithContentsOfFile: (NSString *)path
{
  return AUTORELEASE([[GSMutableStringClass allocWithZone:
    NSDefaultMallocZone()] initWithContentsOfFile: path]);
}

+ (NSString*) stringWithCString: (const char*)byteString
{
  return AUTORELEASE([[GSMutableStringClass allocWithZone:
    NSDefaultMallocZone()] initWithCString: byteString]);
}

+ (NSString*) stringWithCString: (const char*)byteString
			 length: (unsigned)length
{
  return AUTORELEASE([[GSMutableStringClass allocWithZone:
    NSDefaultMallocZone()] initWithCString: byteString length: length]);
}

+ (NSString*) stringWithFormat: (NSString*)format, ...
{
  va_list ap;
  va_start(ap, format);
  self = [super stringWithFormat: format arguments: ap];
  va_end(ap);
  return self;
}

// Designated initialiser 
- (id) initWithCapacity: (unsigned)capacity
{
  [self subclassResponsibility: _cmd];
  return self;
}

- (id) initWithCharactersNoCopy: (unichar*)chars
			 length: (unsigned)length
		   freeWhenDone: (BOOL)flag
{
  if ((self = [self initWithCapacity: length]) != nil && length > 0)
    {
      NSString	*tmp;

      tmp = [NSString allocWithZone: NSDefaultMallocZone()];
      tmp = [tmp initWithCharactersNoCopy: chars
				   length: length
			     freeWhenDone: flag];
      [self replaceCharactersInRange: NSMakeRange(0,0) withString: tmp];
      RELEASE(tmp);
    }
  return self;
}

- (id) initWithCStringNoCopy: (char*)chars
		      length: (unsigned)length
		freeWhenDone: (BOOL)flag
{
  if ((self = [self initWithCapacity: length]) != nil && length > 0)
    {
      NSString	*tmp;

      tmp = [NSString allocWithZone: NSDefaultMallocZone()];
      tmp = [tmp initWithCStringNoCopy: chars
				length: length
			  freeWhenDone: flag];
      [self replaceCharactersInRange: NSMakeRange(0,0) withString: tmp];
      RELEASE(tmp);
    }
  return self;
}

// Modify A String

- (void) appendString: (NSString*)aString
{
  NSRange aRange;

  aRange.location = [self length];
  aRange.length = 0;
  [self replaceCharactersInRange: aRange withString: aString];
}

/* Inefficient. */
- (void) appendFormat: (NSString*)format, ...
{
  va_list	ap;
  id		tmp;

  va_start(ap, format);
  tmp = [[NSStringClass allocWithZone: NSDefaultMallocZone()]
    initWithFormat: format arguments: ap];
  va_end(ap);
  [self appendString: tmp];
  RELEASE(tmp);
}

- (Class) classForCoder
{
  return NSMutableStringClass;
}

- (void) deleteCharactersInRange: (NSRange)range
{
  [self replaceCharactersInRange: range withString: nil];
}

- (void) insertString: (NSString*)aString atIndex: (unsigned)loc
{
  NSRange range = {loc, 0};
  [self replaceCharactersInRange: range withString: aString];
}

- (void) replaceCharactersInRange: (NSRange)range 
		       withString: (NSString*)aString
{
  [self subclassResponsibility: _cmd];
}

- (void) setString: (NSString*)aString
{
  NSRange range = {0, [self length]};
  [self replaceCharactersInRange: range withString: aString];
}

@end

#ifndef NO_GNUSTEP

@implementation NSString (GSTrimming)

- (NSString*) stringByTrimmingLeadWhiteSpaces
{
  NSCharacterSet	*nonSPSet;
  NSRange		nonSPCharRange;

  nonSPSet = [[NSCharacterSet whitespaceAndNewlineCharacterSet] invertedSet];
  nonSPCharRange = [self rangeOfCharacterFromSet: nonSPSet];
  
  if (nonSPCharRange.length > 0)
    return [self substringFromIndex: nonSPCharRange.location];
  else
    return @"";
}

- (NSString*) stringByTrimmingTailWhiteSpaces
{
  NSCharacterSet	*nonSPSet;
  NSRange		nonSPCharRange;

  nonSPSet= [[NSCharacterSet whitespaceAndNewlineCharacterSet] invertedSet];
  nonSPCharRange = [self rangeOfCharacterFromSet: nonSPSet
					 options: NSBackwardsSearch];
  if (nonSPCharRange.length > 0)
    return [self substringToIndex: nonSPCharRange.location+1];
  else
    return @"";
}

- (NSString*) stringByTrimmingWhiteSpaces
{
  return [[self stringByTrimmingLeadWhiteSpaces]
    stringByTrimmingTailWhiteSpaces];
}

- (NSString*) stringByTrimmingLeadSpaces
{
  NSMutableString	*tmp = [self mutableCopy];
  NSString		*str;

  [tmp trimLeadSpaces];
  str = AUTORELEASE([tmp copy]);
  RELEASE(tmp);
  return str;
}

- (NSString*) stringByTrimmingTailSpaces
{
  NSMutableString	*tmp = [self mutableCopy];
  NSString		*str;

  [tmp trimTailSpaces];
  str = AUTORELEASE([tmp copy]);
  RELEASE(tmp);
  return str;
}

- (NSString*) stringByTrimmingSpaces
{
  NSMutableString	*tmp = [self mutableCopy];
  NSString		*str;

  [tmp trimLeadSpaces];
  [tmp trimTailSpaces];
  str = AUTORELEASE([tmp copy]);
  RELEASE(tmp);
  return str;
}

@end

@implementation NSMutableString (GSTrimming)

- (void) trimLeadSpaces
{
  unsigned	location = 0;
  unsigned	length = [self length];
  unichar	(*caiImp)(NSString*, SEL, unsigned);

  caiImp = (unichar (*)())[self methodForSelector: caiSel];
  while (location < length && isspace((*caiImp)(self, caiSel, location)))
    {
      location++;
    }
  if (location > 0)
    {
      [self deleteCharactersInRange: NSMakeRange(0,location)];
    }
}

- (void) trimTailSpaces
{
  unsigned	length = [self length];

  if (length > 0)
    {
      unsigned	location = length;
      unichar	(*caiImp)(NSString*, SEL, unsigned);
        
      caiImp = (unichar (*)())[self methodForSelector: caiSel];
      while (location > 0)
	{
	  if (!isspace((*caiImp)(self, caiSel, --location)))
	    {
	      break;
	    }
	}
      if (location < length-1)
	{
	  [self deleteCharactersInRange: NSMakeRange((location == 0) ? 0
	    : location + 1, length - ((location == 0) ? 0 : location + 1))];
	}
    }
}

- (void) trimSpaces
{
  [self trimLeadSpaces];
  [self trimTailSpaces];
}
        
@end

@implementation NSString (GNUstep)

- (NSString*) stringWithoutSuffix: (NSString*)_suffix
{
  NSCAssert2([self hasSuffix: _suffix],
    @"'%@' has not the suffix '%@'",self,_suffix);
  return [self substringToIndex: ([self length] - [_suffix length])];
}

- (NSString*) stringWithoutPrefix: (NSString*)_prefix
{
  NSCAssert2([self hasPrefix: _prefix],
    @"'%@' has not the prefix '%@'",self,_prefix);
  return [self substringFromIndex: [_prefix length]];
}

- (NSString*) stringByReplacingString: (NSString*)replace
			   withString: (NSString*)by
{
  NSRange range = [self rangeOfString: replace];

  if (range.length > 0)
    {
      NSMutableString	*tmp = [self mutableCopy];
      NSString		*str;

      [tmp replaceString: replace withString: by];
      str = AUTORELEASE([tmp copy]);
      RELEASE(tmp);
      return str;
    }
  else
    return self;
}

@end

@implementation NSMutableString (GNUstep)
- (void) removeSuffix: (NSString*)_suffix
{
  NSCAssert2([self hasSuffix: _suffix],
    @"'%@' has not the suffix '%@'",self,_suffix);
  [self deleteCharactersInRange:
    NSMakeRange([self length] - [_suffix length], [_suffix length])];
}

- (void) removePrefix: (NSString*)_prefix;
{
  NSCAssert2([self hasPrefix: _prefix],
    @"'%@' has not the prefix '%@'",self,_prefix);
  [self deleteCharactersInRange: NSMakeRange(0, [_prefix length])];
}

- (void) replaceString: (NSString*)replace
	    withString: (NSString*)by
{
  NSRange	range = [self rangeOfString: replace];

  if (range.length > 0)
    {
      unsigned	byLen = [by length];

      do
	{
	  [self replaceCharactersInRange: range
			      withString: by];
	  range.location += byLen;
	  range.length = [self length] - range.location;
	  range = [self rangeOfString: replace
			      options: 0
				range: range];
	}
      while (range.length > 0);
    }
}
@end



#if	HAVE_LIBXML
#include	<Foundation/GSXML.h>

#ifndef __XML_TREE_H__
static int      XML_ELEMENT_NODE;
#endif

static void
decodeBase64Unit(const char* ptr, unsigned char *out)
{
  out[0] =  (ptr[0]         << 2) | ((ptr[1] & 0x30) >> 4);
  out[1] = ((ptr[1] & 0x0F) << 4) | ((ptr[2] & 0x3C) >> 2);
  out[2] = ((ptr[2] & 0x03) << 6) |  (ptr[3] & 0x3F);
  out[3] = 0;
}

static NSData*
decodeBase64(const char *source)
{
  int		length = strlen(source);
  char		*sourceBuffer = objc_malloc(length+1);
  NSMutableData	*data = [NSMutableData dataWithCapacity:0];
  int i, j;
  unsigned char	tmp[4];

  strcpy(sourceBuffer, source);
  j = 0;

  for (i = 0; i < length; i++)
    {
      if (!isspace(source[i]))
        {
          sourceBuffer[j++] = source[i];
        }
    }

  sourceBuffer[j] = '\0';
  length = strlen(sourceBuffer);
  while (length > 0 && sourceBuffer[length-1] == '=')
    {
      sourceBuffer[--length] = '\0';
    }
  for (i = 0; i < length; i += 4)
    {
       decodeBase64Unit(&sourceBuffer[i], tmp);
       [data appendBytes: tmp length: strlen(tmp)];
    }

  objc_free(sourceBuffer);

  return data;
}

#endif

#define inrange(ch,min,max) ((ch)>=(min) && (ch)<=(max))
#define char2num(ch) \
inrange(ch,'0','9') \
? ((ch)-0x30) \
: (inrange(ch,'a','f') \
? ((ch)-0x57) : ((ch)-0x37))

typedef	struct	{
  const unichar	*ptr;
  unsigned	end;
  unsigned	pos;
  unsigned	lin;
  NSString	*err;
} pldata;

/*
 *	Property list parsing - skip whitespace keeping count of lines and
 *	regarding objective-c style comments as whitespace.
 *	Returns YES if there is any non-whitespace text remaining.
 */
static BOOL skipSpace(pldata *pld)
{
  unichar	c;

  while (pld->pos < pld->end)
    {
      c = pld->ptr[pld->pos];

      if (GS_IS_WHITESPACE(c) == NO)
	{
	  if (c == '/' && pld->pos < pld->end - 1)
	    {
	      /*
	       * Check for comments beginning '/' followed by '/' or '*'
	       */
	      if (pld->ptr[pld->pos + 1] == '/')
		{
		  pld->pos += 2;
		  while (pld->pos < pld->end)
		    {
		      c = pld->ptr[pld->pos];
		      if (c == '\n')
			break;
		      pld->pos++;
		    }
		  if (pld->pos >= pld->end)
		    {
		      pld->err = @"reached end of string in comment";
		      return NO;
		    }
		}
	      else if (pld->ptr[pld->pos + 1] == '*')
		{
		  pld->pos += 2;
		  while (pld->pos < pld->end)
		    {
		      c = pld->ptr[pld->pos];
		      if (c == '\n')
			pld->lin++;
		      else if (c == '*' && pld->pos < pld->end - 1
			&& pld->ptr[pld->pos+1] == '/')
			{
			  pld->pos++; /* Skip past '*'	*/
			  break;
			}
		      pld->pos++;
		    }
		  if (pld->pos >= pld->end)
		    {
		      pld->err = @"reached end of string in comment";
		      return NO;
		    }
		}
	      else
		return YES;
	    }
	  else
	    return YES;
	}
      if (c == '\n')
	pld->lin++;
      pld->pos++;
    }
  pld->err = @"reached end of string";
  return NO;
}

static inline id parseQuotedString(pldata* pld)
{
  unsigned	start = ++pld->pos;
  unsigned	escaped = 0;
  unsigned	shrink = 0;
  BOOL		hex = NO;
  NSString	*obj;

  while (pld->pos < pld->end)
    {
      unichar	c = pld->ptr[pld->pos];

      if (escaped)
	{
	  if (escaped == 1 && c >= '0' && c <= '7')
	    {
	      escaped = 2;
	      hex = NO;
	    }
	  else if (escaped == 1 && c == 'U')
	    {
	      escaped = 2;
	      shrink++;
	      hex = YES;
	    }
	  else if (escaped > 1)
	    {
	      if (hex && GS_IS_HEXDIGIT(c))
		{
		  shrink++;
		  escaped++;
		  if (escaped == 10)
		    {
		      escaped = 0;
		    }
		}
	      else if (c >= '0' && c <= '7')
		{
		  shrink++;
		  if (escaped == 4)
		    {
		      escaped = 0;
		    }
		}
	      else
		{
		  pld->pos--;
		  escaped = 0;
		}
	    }
	  else
	    {
	      escaped = 0;
	    }
	}
      else
	{
	  if (c == '\\')
	    {
	      escaped = 1;
	      shrink++;
	    }
	  else if (c == '"')
	    {
	      break;
	    }
	}
      if (c == '\n')
	pld->lin++;
      pld->pos++;
    }
  if (pld->pos >= pld->end)
    {
      pld->err = @"reached end of string while parsing quoted string";
      return nil;
    }
  if (pld->pos - start - shrink == 0)
    {
      obj = @"";
    }
  else
    {
      unichar	chars[pld->pos - start - shrink];
      unsigned	j;
      unsigned	k;

      escaped = 0;
      hex = NO;
      for (j = start, k = 0; j < pld->pos; j++)
	{
	  unichar	c = pld->ptr[j];

	  if (escaped)
	    {
	      if (escaped == 1 && c >= '0' && c <= '7')
		{
		  chars[k] = 0;
		  hex = NO;
		  escaped++;
		}
	      else if (escaped == 1 && c == 'U')
		{
		  chars[k] = 0;
		  hex = YES;
		  escaped++;
		}
	      else if (escaped > 1)
		{
		  if (hex && GS_IS_HEXDIGIT(c))
		    {
		      chars[k] <<= 4;
		      chars[k] |= char2num(c);
		      escaped++;
		      if (escaped == 10)
			{
			  escaped = 0;
			}
		    }
		  else if (c >= '0' && c <= '7')
		    {
		      chars[k] <<= 3;
		      chars[k] |= (c - '0');
		      escaped++;
		      if (escaped == 4)
			{
			  escaped = 0;
			}
		    }
		  else
		    {
		      escaped = 0;
		      j--;
		      k++;
		    }
		}
	      else
		{
		  escaped = 0;
		  switch (c)
		    {
		      case 'a' : chars[k] = '\a'; break;
		      case 'b' : chars[k] = '\b'; break;
		      case 't' : chars[k] = '\t'; break;
		      case 'r' : chars[k] = '\r'; break;
		      case 'n' : chars[k] = '\n'; break;
		      case 'v' : chars[k] = '\v'; break;
		      case 'f' : chars[k] = '\f'; break;
		      default  : chars[k] = c; break;
		    }
		  k++;
		}
	    }
	  else
	    {
	      chars[k] = c;
	      if (c == '\\')
		{
		  escaped = 1;
		}
	      else
		{
		  k++;
		}
	    }
	}
      obj = (*plAlloc)(NSStringClass, @selector(allocWithZone:),
	NSDefaultMallocZone());
      obj = (*plInit)(obj, plSel, (void*)chars, pld->pos - start - shrink);
    }
  pld->pos++;
  return obj;
}

static inline id parseUnquotedString(pldata *pld)
{
  unsigned	start = pld->pos;
  id		obj;

  while (pld->pos < pld->end)
    {
      if (GS_IS_QUOTABLE(pld->ptr[pld->pos]) == YES)
	break;
      pld->pos++;
    }
  obj = (*plAlloc)(NSStringClass, @selector(allocWithZone:),
    NSDefaultMallocZone());
  obj = (*plInit)(obj, plSel, (void*)&pld->ptr[start], pld->pos-start);
  return obj;
}

static id parsePlItem(pldata* pld)
{
  if (skipSpace(pld) == NO)
    return nil;

  switch (pld->ptr[pld->pos])
    {
      case '{':
	{
	  NSMutableDictionary	*dict;

	  dict = [[plDictionary allocWithZone: NSDefaultMallocZone()]
	    initWithCapacity: 0];
	  pld->pos++;
	  while (skipSpace(pld) == YES && pld->ptr[pld->pos] != '}')
	    {
	      id	key;
	      id	val;

	      key = parsePlItem(pld);
	      if (key == nil)
		return nil;
	      if (skipSpace(pld) == NO)
		{
		  RELEASE(key);
		  RELEASE(dict);
		  return nil;
		}
	      if (pld->ptr[pld->pos] != '=')
		{
		  pld->err = @"unexpected character (wanted '=')";
		  RELEASE(key);
		  RELEASE(dict);
		  return nil;
		}
	      pld->pos++;
	      val = parsePlItem(pld);
	      if (val == nil)
		{
		  RELEASE(key);
		  RELEASE(dict);
		  return nil;
		}
	      if (skipSpace(pld) == NO)
		{
		  RELEASE(key);
		  RELEASE(val);
		  RELEASE(dict);
		  return nil;
		}
	      if (pld->ptr[pld->pos] == ';')
		{
		  pld->pos++;
		}
	      else if (pld->ptr[pld->pos] != '}')
		{
		  pld->err = @"unexpected character (wanted ';' or '}')";
		  RELEASE(key);
		  RELEASE(val);
		  RELEASE(dict);
		  return nil;
		}
	      (*plSet)(dict, @selector(setObject:forKey:), val, key);
	      RELEASE(key);
	      RELEASE(val);
	    }
	  if (pld->pos >= pld->end)
	    {
	      pld->err = @"unexpected end of string when parsing dictionary";
	      RELEASE(dict);
	      return nil;
	    }
	  pld->pos++;
	  return dict;
	}

      case '(':
	{
	  NSMutableArray	*array;

	  array = [[plArray allocWithZone: NSDefaultMallocZone()]
	    initWithCapacity: 0];
	  pld->pos++;
	  while (skipSpace(pld) == YES && pld->ptr[pld->pos] != ')')
	    {
	      id	val;

	      val = parsePlItem(pld);
	      if (val == nil)
		{
		  RELEASE(array);
		  return nil;
		}
	      if (skipSpace(pld) == NO)
		{
		  RELEASE(val);
		  RELEASE(array);
		  return nil;
		}
	      if (pld->ptr[pld->pos] == ',')
		{
		  pld->pos++;
		}
	      else if (pld->ptr[pld->pos] != ')')
		{
		  pld->err = @"unexpected character (wanted ',' or ')')";
		  RELEASE(val);
		  RELEASE(array);
		  return nil;
		}
	      (*plAdd)(array, @selector(addObject:), val);
	      RELEASE(val);
	    }
	  if (pld->pos >= pld->end)
	    {
	      pld->err = @"unexpected end of string when parsing array";
	      RELEASE(array);
	      return nil;
	    }
	  pld->pos++;
	  return array;
	}

      case '<':
	{
	  NSMutableData	*data;
	  unsigned	max = pld->end - 1;
	  unsigned char	buf[BUFSIZ];
	  unsigned	len = 0;

	  data = [[NSMutableData alloc] initWithCapacity: 0];
	  pld->pos++;
	  skipSpace(pld);
	  while (pld->pos < max
		 && GS_IS_HEXDIGIT(pld->ptr[pld->pos])
		 && GS_IS_HEXDIGIT(pld->ptr[pld->pos+1]))
	    {
	      unsigned char	byte;

	      byte = (char2num(pld->ptr[pld->pos])) << 4; 
	      pld->pos++;
	      byte |= char2num(pld->ptr[pld->pos]);
	      pld->pos++;
	      buf[len++] = byte;
	      if (len == sizeof(buf))
		{
		  [data appendBytes: buf length: len];
		  len = 0;
		}
	      skipSpace(pld);
	    }
	  if (pld->pos >= pld->end)
	    {
	      pld->err = @"unexpected end of string when parsing data";
	      RELEASE(data);
	      return nil;
	    }
	  if (pld->ptr[pld->pos] != '>')
	    {
	      pld->err = @"unexpected character in string";
	      RELEASE(data);
	      return nil;
	    }
	  if (len > 0)
	    {
	      [data appendBytes: buf length: len];
	    }
	  pld->pos++;
	  return data;
	}

      case '"':
	return parseQuotedString(pld);

      default:
	return parseUnquotedString(pld);
    }
}

#if	HAVE_LIBXML
static GSXMLNode*
elementNode(GSXMLNode* node)
{
  while (node != nil)
    {
      if ([node type] == XML_ELEMENT_NODE)
        {
          break;
        }
      node = [node next];
    }
  return node;
}

static id
nodeToObject(GSXMLNode* node)
{
  NSString	*name;
  NSString	*content;
  GSXMLNode	*children;

  node = elementNode(node);
  if (node == nil)
    {
      return nil;
    }
  name = [node name];
  children = [node children];
  content = [children content];
  children = elementNode(children);

  if ([name isEqualToString: @"string"])
    {
      return content;
    }
  else if ([name isEqualToString: @"key"])
    {
      return content;
    }
  else if ([name isEqualToString: @"true"])
    {
      return [NSNumber numberWithBool: YES];
    }
  else if ([name isEqualToString: @"false"])
    {
      return [NSNumber numberWithBool: NO];
    }
  else if ([name isEqualToString: @"integer"])
    {
      return [NSNumber numberWithInt: [content intValue]];
    }
  else if ([name isEqualToString: @"real"])
    {
      return [NSNumber numberWithDouble: [content doubleValue]];
    }
  else if ([name isEqualToString: @"date"])
    {
      return [NSCalendarDate dateWithString: content
                             calendarFormat: @"%Y-%m-%d %H:%M:%S %z"];
    }
  else if ([name isEqualToString: @"data"])
    {
      return decodeBase64([content cString]);
    }
  // container class
  else if ([name isEqualToString: @"array"])
    {
      NSMutableArray	*container = [NSMutableArray array];

      while (children != nil)
        {
	  id	val;

	  val = nodeToObject(children);
          [container addObject: val];
          children = elementNode([children next]);
        }
      return container;
    }
  else if ([name isEqualToString: @"dict"])
    {
      NSMutableDictionary	*container = [NSMutableDictionary dictionary];

      while (children != nil)
        {
	  NSString	*key;
	  id		val;

	  key = nodeToObject(children);
          children = elementNode([children next]);
	  val = nodeToObject(children);
          children = elementNode([children next]);
          [container setObject: val forKey: key];
        }
      return container;
    }
  else
    {
      return nil;
    }
}
#endif

static void
setupPl()
{
#if	HAVE_LIBXML
#ifndef __XML_TREE_H__
  /*
   * Cache XML node information.
   */
  XML_ELEMENT_NODE = [GSXMLNode typeFromDescription: @"XML_ELEMENT_NODE"];
#endif
#endif
  plAlloc = (id (*)(id, SEL, NSZone*))
    [NSStringClass methodForSelector: @selector(allocWithZone:)];
  plInit = (id (*)(id, SEL, unichar*, unsigned))
    [NSStringClass instanceMethodForSelector: plSel];

  plArray = [GSMutableArray class];
  plAdd = (id (*)(id, SEL, id))
    [plArray instanceMethodForSelector: @selector(addObject:)];

  plDictionary = [GSMutableDictionary class];
  plSet = (id (*)(id, SEL, id, id))
    [plDictionary instanceMethodForSelector: @selector(setObject:forKey:)];

  setupHexdigits();
  setupQuotables();
  setupWhitespace();
}

static id
GSPropertyList(NSString *string)
{
  pldata	_pld;
  pldata	*pld = &_pld;
  unsigned	length = [string length];
  NSData	*d;
  id		pl;
#if	HAVE_LIBXML
  unsigned	index = 0;
#endif

  /*
   * An empty string is a nil property list.
   */
  if (length == 0)
    {
      return nil;
    }

#if	HAVE_LIBXML
  if (whitespaceBitmapRep == NULL)
    {
      setupWhitespace();
    }
  while (index < length)
    {
      unsigned	c = [string characterAtIndex: index];

      if (GS_IS_WHITESPACE(c) == NO)
	{
	  break;
	}
      index++;
    }
  /*
   * A string beginning with a '<?' must be an XML file
   */
  if (index + 1 < length && [string characterAtIndex: index] == '<'
    && [string characterAtIndex: index+1] == '?')
    {
      NSData		*data;
      GSXMLParser	*parser;

      data = [string dataUsingEncoding: NSUTF8StringEncoding]; 
      parser = [GSXMLParser parser];
      [parser substituteEntities: YES];
      [parser doValidityChecking: YES];
      if ([parser parse: data] == NO || [parser parse: nil] == NO)
	{
	  NSLog(@"not a property list - failed to parse as XML");
	  return nil;
	}
      if (![[[[parser doc] root] name] isEqualToString: @"plist"])
	{
	  NSLog(@"not a property list - because name node is %@",
	    [[[parser doc] root] name]);
	  return nil;
	}
      pl = AUTORELEASE(RETAIN(nodeToObject([[[parser doc] root] children])));
      return pl;
    }
#endif
  d = [string dataUsingEncoding: NSUnicodeStringEncoding];
  _pld.ptr = (unichar*)[d bytes];
  _pld.pos = 1;
  _pld.end = length + 1;
  _pld.err = nil;
  _pld.lin = 1;
  if (plAlloc == 0)
    {
      setupPl();
    }
  pl = AUTORELEASE(parsePlItem(pld));
  if (pl == nil && _pld.err != nil)
    {
      NSLog(@"Parse failed at line %d (char %d) - %@",
	_pld.lin, _pld.pos, _pld.err);
    }
  return pl;
}

static id
GSPropertyListFromStringsFormat(NSString *string)
{
  NSMutableDictionary	*dict;
  pldata		_pld;
  pldata		*pld = &_pld;
  unsigned		length = [string length];
  NSData		*d;

  /*
   * An empty string is a nil property list.
   */
  if (length == 0)
    {
      return nil;
    }

  d = [string dataUsingEncoding: NSUnicodeStringEncoding];
  _pld.ptr = (unichar*)[d bytes];
  _pld.pos = 1;
  _pld.end = length + 1;
  _pld.err = nil;
  _pld.lin = 1;
  if (plAlloc == 0)
    {
      setupPl();
    }

  dict = [[plDictionary allocWithZone: NSDefaultMallocZone()]
    initWithCapacity: 0];
  while (skipSpace(pld) == YES)
    {
      id	key;
      id	val;

      if (pld->ptr[pld->pos] == '"')
	{
	  key = parseQuotedString(pld);
	}
      else
	{
	  key = parseUnquotedString(pld);
	}
      if (key == nil)
	{
	  DESTROY(dict);
	  break;
	}
      if (skipSpace(pld) == NO)
	{
	  pld->err = @"incomplete final entry (no semicolon?)";
	  RELEASE(key);
	  DESTROY(dict);
	  break;
	}
      if (pld->ptr[pld->pos] == ';')
	{
	  pld->pos++;
	  (*plSet)(dict, @selector(setObject:forKey:), @"", key);
	  RELEASE(key);
	}
      else if (pld->ptr[pld->pos] == '=')
	{
	  pld->pos++;
	  if (skipSpace(pld) == NO)
	    {
	      RELEASE(key);
	      DESTROY(dict);
	      break;
	    }
	  if (pld->ptr[pld->pos] == '"')
	    {
	      val = parseQuotedString(pld);
	    }
	  else
	    {
	      val = parseUnquotedString(pld);
	    }
	  if (val == nil)
	    {
	      RELEASE(key);
	      DESTROY(dict);
	      break;
	    }
	  if (skipSpace(pld) == NO)
	    {
	      pld->err = @"missing final semicolon";
	      RELEASE(key);
	      RELEASE(val);
	      DESTROY(dict);
	      break;
	    }
	  (*plSet)(dict, @selector(setObject:forKey:), val, key);
	  RELEASE(key);
	  RELEASE(val);
	  if (pld->ptr[pld->pos] == ';')
	    {
	      pld->pos++;
	    }
	  else
	    {
	      pld->err = @"unexpected character (wanted ';')";
	      DESTROY(dict);
	      break;
	    }
	}
      else
	{
	  pld->err = @"unexpected character (wanted '=' or ';')";
	  RELEASE(key);
	  DESTROY(dict);
	  break;
	}
    }
  if (dict == nil && _pld.err != nil)
    {
      NSLog(@"Parse failed at line %d (char %d) - %@",
	_pld.lin, _pld.pos, _pld.err);
    }
  return AUTORELEASE(dict);
}
#endif /* NO_GNUSTEP */
