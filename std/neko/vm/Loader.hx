/*
 * Copyright (c) 2005, The haXe Project Contributors
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *   - Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   - Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE HAXE PROJECT CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE HAXE PROJECT CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */
package neko.vm;

/**
	The Neko object that implements the loader.
**/
enum LoaderHandle {
}

/**
	<p>
	Loaders can be used to dynamicly load Neko primitives stored in NDLL libraries.
	</p>
	<p>
	Loaders can be used to dynamicly load other Neko modules (.n bytecode files).
	Modules are referenced by names. To lookup the corresponding bytecode file, the
	default loader first look in its cache, then eventually adds the .n extension
	to the name and lookup the bytecode in its path.
	</p>
	<p>
	Loaders can be used for sandbox security. When a Module is loaded with a given
	Loader, this loader can manager the module security by filtering which
	primitives can be loaded by this module or by rewrapping them at loading-time
	with custom securized versions. Loaders are inherited in loaded submodules.
	</p>
**/
class Loader {

	/**
		The abstract handle.
	**/
	public var l : LoaderHandle;

	public function new( l ) {
		this.l = l;
	}

	/**
		The default loader contains a search path in its [path] field. It's a
		linked list of Neko strings that is a parsed version of the [NEKOPATH].
		This path is used to lookup for modules and libraries.
	**/
	public function getPath() {
		var p = untyped l.path;
		var path = new Array<String>();
		while( p != null ) {
			path.push(new String(p[0]));
			p = cast p[1];
		}
		return path;
	}

	/**
		Adds a directory to the search path. See [getPath]
	**/
	public function addPath( s : String ) {
		untyped l.path = __dollar__array(s.__s,l.path);
	}

	/**
		The default loader contains a cache of already loaded modules. It's
		ensuring that the same module does not get loaded twice when circular
		references are occuring. The same module can eventually be loaded twice
		but with different names, for example with two relatives paths reprensenting
		the same file, since the cache is done on a by-name basic.
	**/
	public function getCache() : Hash<Module> {
		var h = new Hash<Module>();
		var cache = untyped l.cache;
		for( f in Reflect.fields(cache) )
			h.set(f,new Module(Reflect.field(cache,f)));
		return h;
	}

	/**
		Set a module in the loader cache.
	**/
	public function setCache( name : String, m : Module ) {
		Reflect.setField(untyped l.cache,name,m.m);
	}

	/**
		Change the cache value and returns the old value. This can be used
		to backup the loader cache and restore it later.
	**/
	public function backupCache( c : Dynamic ) : Dynamic {
		var old = untyped l.cache;
		untyped l.cache = c;
		return old;
	}

	function __compare( other : Loader ) {
		return untyped __dollar__compare(this.l,other.l);
	}

	/**
		Loads a neko primitive. By default, the name is of the form [library@method].
		The primitive might not be used directly in haXe since some of the Neko values
		needs an object wrapper in haXe.
	**/
	public function loadPrimitive( prim : String, nargs : Int ) : Dynamic {
		return untyped l.loadprim(prim.__s,nargs);
	}

	/**
		Loads a Module with the given name. If [loader] is defined, this will be
		this Module loader, else this loader will be inherited. When loaded this
		way, the module is directly executed.
	**/
	public function loadModule( modName : String, ?loader : Loader ) : Module {
		var exp = untyped l.loadmodule(modName.__s,if( loader == null ) l else loader.l);		
		return new Module(exp.__module);
	}

	/**
		Returns the local Loader. This is the loader that was used to load the
		module in which the code is defined.
	**/
	public static function local() {
		return new Loader(untyped __dollar__loader);
	}

	/**
		Creates a loader using two methods. This loader will not have an accessible cache or path,
		although you can implement such mecanism in the methods body.
	**/
	public static function make( loadPrim : String -> Int -> Dynamic, loadModule : String -> Loader -> Module ) {
		var l = {
			loadprim : function(prim,nargs) {
				return loadPrim(new String(prim),nargs);
			},
			loadmodule : function(mname,loader) {
				return loadModule(new String(mname),new Loader(loader)).exportsTable();
			}
		};
		return new Loader(cast l);
	}

}