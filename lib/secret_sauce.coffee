SecretSauce =
  mixin: (module, klass) ->
    for key, fn of @[module]
      klass.prototype[key] = fn

SecretSauce.Keys =
  _convertToId: (index) ->
    ival = index.toString(36)
    ## 0 pad number to ensure three digits
    [0,0,0].slice(ival.length).join("") + ival

  _getProjectKeyRange: (id) ->
    @cache.getProject(id).get("RANGE")

  ## Lookup the next Test integer and update
  ## offline location of sync
  getNextTestNumber: (projectId) ->
    @_getProjectKeyRange(projectId)
    .then (range) =>
      return @_getNewKeyRange(projectId) if range.start is range.end

      range.start += 1
      range
    .then (range) =>
      range = JSON.parse(range) if SecretSauce._.isString(range)
      @Log.info "Received key range", {range: range}
      @cache.updateRange(projectId, range)
      .return(range.start)

  nextKey: ->
    @project.ensureProjectId().bind(@)
    .then (projectId) ->
      @cache.ensureProject(projectId).bind(@)
      .then -> @getNextTestNumber(projectId)
      .then @_convertToId

SecretSauce.Socket =
  leadingSlashes: /^\/+/

  onTestFileChange: (filePath, stats) ->
    @Log.info "onTestFileChange", filePath: filePath

    ## simple solution for preventing firing test:changed events
    ## when we are making modifications to our own files
    return if @app.enabled("editFileMode")

    ## return if we're not a js or coffee file.
    ## this will weed out directories as well
    return if not /\.(js|coffee)$/.test filePath

    @fs.statAsync(filePath).bind(@)
      .then ->
        ## strip out our testFolder path from the filePath, and any leading forward slashes
        filePath      = filePath.split(@app.get("cypress").projectRoot).join("").replace(@leadingSlashes, "")
        strippedPath  = filePath.replace(@app.get("cypress").testFolder, "").replace(@leadingSlashes, "")

        @Log.info "generate:ids:for:test", filePath: filePath, strippedPath: strippedPath
        @io.emit "generate:ids:for:test", filePath, strippedPath
      .catch(->)

  closeWatchers: ->
    if f = @watchedTestFile
      f.close()

  watchTestFileByPath: (testFilePath) ->
    ## normalize the testFilePath
    testFilePath = @path.join(@testsDir, testFilePath)

    ## bail if we're already watching this
    ## exact file
    return if testFilePath is @testFilePath

    @Log.info "watching test file", {path: testFilePath}

    ## store this location
    @testFilePath = testFilePath

    ## close existing watchedTestFile(s)
    ## since we're now watching a different path
    @closeWatchers()

    new @Promise (resolve, reject) =>
      @watchedTestFile = @chokidar.watch testFilePath
      @watchedTestFile.on "change", @onTestFileChange.bind(@)
      @watchedTestFile.on "ready", =>
        resolve @watchedTestFile
      @watchedTestFile.on "error", (err) =>
        @Log.info "watching test file failed", {error: err, path: testFilePath}
        reject err

  _startListening: (chokidar, path) ->
    { _ } = SecretSauce

    messages = {}

    @io.on "connection", (socket) =>
      @Log.info "socket connected"

      socket.on "remote:connected", ->
        return if socket.inRemoteRoom

        socket.inRemoteRoom = true
        socket.join("remote")

        socket.on "remote:response", (id, response) ->
          if message = messages[id]
            delete messages[id]
            message(response)

      socket.on "client:request", (message, data, cb) =>
        ## if cb isnt a function then we know
        ## data is really the cb, so reassign it
        ## and set data to null
        if not _.isFunction(cb)
          cb = data
          data = null

        id = @uuid.v4()

        if _.keys(@io.sockets.adapter.rooms.remote).length > 0
          messages[id] = cb
          @io.to("remote").emit "remote:request", id, message, data
        else
          cb({__error: "Could not process '#{message}'. No remote servers connected."})

      socket.on "watch:test:file", (filePath) =>
        @watchTestFileByPath(filePath)

      socket.on "generate:test:id", (data, fn) =>
        @Log.info "generate:test:id", data: data

        @idGenerator.getId(data)
        .then(fn)
        .catch (err) ->
          console.log "\u0007", err.details, err.message
          fn(message: err.message)

      socket.on "finished:generating:ids:for:test", (strippedPath) =>
        @Log.info "finished:generating:ids:for:test", strippedPath: strippedPath
        @io.emit "test:changed", file: strippedPath

      _.each "load:spec:iframe command:add runner:start runner:end before:run before:add after:add suite:add suite:start suite:stop test test:add test:start test:end after:run test:results:ready exclusive:test".split(" "), (event) ->
        socket.on event, (args...) =>
          args = _.chain(args).compact().reject(_.isFunction).value()
          @io.emit event, args...

      ## when we're told to run:sauce we receive
      ## the spec and callback with the name of our
      ## sauce labs job
      ## we'll embed some additional meta data into
      ## the job name
      socket.on "run:sauce", (spec, fn) =>
        ## this will be used to group jobs
        ## together for the runs related to 1
        ## spec by setting custom-data on the job object
        batchId = Date.now()

        jobName = @app.get("cypress").testFolder + "/" + spec
        fn(jobName, batchId)

        ## need to handle platform/browser/version incompatible configurations
        ## and throw our own error
        ## https://saucelabs.com/platforms/webdriver
        jobs = [
          { platform: "Windows 8.1", browser: "internet explorer",  version: 11 }
          { platform: "Windows 7",   browser: "internet explorer",  version: 10 }
          { platform: "Linux",       browser: "chrome",             version: 37 }
          { platform: "Linux",       browser: "firefox",            version: 33 }
          { platform: "OS X 10.9",   browser: "safari",             version: 7 }
        ]

        normalizeJobObject = (obj) ->
          obj = _(obj).clone()

          obj.browser = {
            "internet explorer": "ie"
          }[obj.browserName] or obj.browserName

          obj.os = obj.platform

          _(obj).pick "name", "browser", "version", "os", "batchId", "guid"

        _.each jobs, (job) =>
          options =
            host:        "0.0.0.0"
            port:        @app.get("port")
            name:        jobName
            batchId:     batchId
            guid:        uuid.v4()
            browserName: job.browser
            version:     job.version
            platform:    job.platform

          clientObj = normalizeJobObject(options)
          socket.emit "sauce:job:create", clientObj

          df = jQuery.Deferred()

          df.progress (sessionID) ->
            ## pass up the sessionID to the previous client obj by its guid
            socket.emit "sauce:job:start", clientObj.guid, sessionID

          df.fail (err) ->
            socket.emit "sauce:job:fail", clientObj.guid, err

          df.done (sessionID, runningTime, passed) ->
            socket.emit "sauce:job:done", sessionID, runningTime, passed

          sauce options, df

    @testsDir = path.join(@app.get("cypress").projectRoot, @app.get("cypress").testFolder)

    @fs.ensureDirAsync(@testsDir).bind(@)

    ## BREAKING DUE TO __DIRNAME
    # watchCssFiles = chokidar.watch path.join(__dirname, "public", "css"), ignored: (path, stats) ->
    #   return false if fs.statSync(path).isDirectory()

    #   not /\.css$/.test path

    # # watchCssFiles.on "add", (path) -> console.log "added css:", path
    # watchCssFiles.on "change", (filePath, stats) =>
    #   filePath = path.basename(filePath)
    #   @io.emit "eclectus:css:changed", file: filePath

SecretSauce.IdGenerator =
  hasExistingId: (e) ->
    e.idFound

  idFound: ->
    e = new Error
    e.idFound = true
    throw e

  nextId: (data) ->
    @keys.nextKey().bind(@)
    .then((id) ->
      @Log.info "Appending ID to Spec", {id: id, spec: data.spec, title: data.title}
      @appendTestId(data.spec, data.title, id)
      .return(id)
    )
    .catch (e) ->
      @logErr(e, data.spec)

      throw e

  appendTestId: (spec, title, id) ->
    normalizedPath = @path.join(@projectRoot, spec)

    @read(normalizedPath).bind(@)
    .then (contents) ->
      @insertId(contents, title, id)
    .then (contents) ->
      ## enable editFileMode which prevents us from sending out test:changed events
      @editFileMode(true)

      ## write the new content back to the file
      @write(normalizedPath, contents)
    .then ->
      ## remove the editFileMode so we emit file changes again
      ## if we're still in edit file mode then wait 1 second and disable it
      ## chokidar doesnt instantly see file changes so we have to wait
      @editFileMode(false, {delay: 1000})
    .catch @hasExistingId, (err) ->
      ## do nothing when the ID is existing

  insertId: (contents, title, id) ->
    re = new RegExp "['\"](" + @escapeRegExp(title) + ")['\"]"

    # ## if the string is found and it doesnt have an id
    matches = re.exec contents

    ## matches[1] will be the captured group which is the title
    return @idFound() if not matches

    ## position is the string index where we first find the capture
    ## group and include its length, so we insert right after it
    position = matches.index + matches[1].length + 1
    @str.insert contents, position, " [#{id}]"

SecretSauce.RemoteProxy =
  okStatus: /^[2|3]\d+$/

  _handle: (req, res, next, Domain, httpProxy) ->
    ## TODO TEST THIS BASEURL FALLBACK
    remoteHost = @getOriginFromFqdnUrl(req) ? req.cookies["__cypress.remoteHost"] ? @app.get("cypress").baseUrl

    ## we must have the remoteHost cookie
    if not remoteHost
      throw new Error("Missing remoteHost!")

    domain = Domain.create()

    domain.on 'error', (err) =>
      @errorHandler(err, req, res, remoteHost)

    domain.run =>
      @getContentStream(req, res, remoteHost, httpProxy)
      .on 'error', (err) =>
        @errorHandler(err, req, res, remoteHost)
      .pipe(res)

  getOriginFromFqdnUrl: (req) ->
    ## if we find an origin from this req.url
    ## then return it, and reset our req.url
    ## after stripping out the origin and ensuring
    ## our req.url starts with only 1 leading slash
    if origin = @UrlHelpers.getOriginFromFqdnUrl(req.url)
      req.url = "/" + req.url.replace(origin, "").replace(/^\/+/, "")

      ## return the origin
      return origin

  getContentStream: (req, res, remoteHost, httpProxy) ->
    switch remoteHost
      ## serve from the file system because
      ## we are using cypress as our weberver
      when "<root>"
        @getFileStream(req, res, remoteHost)

      ## else go make an HTTP request to the
      ## real server!
      else
        @getHttpStream(req, res, remoteHost, httpProxy)

  # creates a read stream to a file stored on the users filesystem
  # taking into account if they've chosen a specific rootFolder
  # that their project files exist in
  getFileStream: (req, res, remoteHost) ->
    { _ } = SecretSauce

    ## strip off any query params from our req's url
    ## since we're pulling this from the file system
    ## it does not understand query params
    pathname = @url.parse(req.url).pathname

    res.contentType(@mime.lookup(pathname))

    args = _.compact([
      @app.get("cypress").projectRoot,
      @app.get("cypress").rootFolder,
      pathname
    ])

    @fs.createReadStream  @path.join(args...)

  getHttpStream: (req, res, remoteHost, httpProxy) ->
    { _ } = SecretSauce

    # @emit "verbose", "piping url content #{opts.uri}, #{opts.uri.split(opts.remote)[1]}"
    @Log.info "piping http url content", url: req.url, remoteHost: remoteHost

    selectors = []

    # tr = @trumpet()

    thr = @through

    t = @through (d) -> @queue(d)

    toInject = "
      <script type='text/javascript'>
        window.onerror = function(){
          parent.onerror.apply(parent, arguments);
        }
      </script>
      <script type='text/javascript' src='/__cypress/static/js/sinon.js'></script>
      <script type='text/javascript'>
        var Cypress = parent.Cypress;
        if (!Cypress){
          throw new Error('Cypress must exist in the parent window!');
        };
        Cypress.onBeforeLoad(window);
      </script>
    "

    rewrite = (selector, type, attr, fn) ->
      if _.isFunction(attr)
        fn   = attr
        attr = null

      selectors.push {
        query: selector
        func: (elem) ->
          switch type
            when "attr"
              elem.getAttribute attr, (val) ->
                elem.setAttribute attr, fn(val)
            when "html"
              stream = elem.createStream({outer: true})
              stream.pipe(thr (buf) ->
                @queue fn(buf.toString())
              ).pipe(stream)
      }
      # tr.selectAll selector, (elem) ->
        # elem.getAttribute attr, (val) ->
        #   elem.setAttribute attr, fn(val)

    rewrite "head", "html", (str) ->
      str.replace(/<head>/, "<head> #{toInject}")

    rewrite "[href^='//']", "attr", "href", (href) ->
      "/" + req.protocol + ":" + href

    rewrite "form[action^='//']", "attr", "action", (action) ->
      "/" + req.protocol + ":" + action

    rewrite "form[action^='http']", "attr", "action", (action) ->
      if action.startsWith(remoteHost)
        action.replace(remoteHost, "")
      else
        "/" + action

    rewrite "[href^='http']", "attr", "href", (href) ->
      if href.startsWith(remoteHost)
        href.replace(remoteHost, "")
      else
        "/" + href

    h = @harmon([], selectors, true)

    ## we pass an empty function as next()
    ## because we arent using harmon as middleware
    # h(req, res, ->)

    proxy = httpProxy.createProxyServer({})

    proxy.once "error", (err) =>
      if req.cookies["__cypress.initial"] is "true"
        @errorHandler err, req, res, remoteHost
      else
        throw err

    proxy.once "proxyRes", (proxyRes, req, res) =>
      if req.cookies["__cypress.initial"] is "true"
        if not @okStatus.test proxyRes.statusCode
          @errorHandler null, req, res, remoteHost, proxyRes

    # proxy.once "proxyReq", (proxyReq, req, res) ->

    ## hostRewrite: rewrites location header on redirects back to
    ## ourselves (localhost:2020) so the client will automatically
    ## re-request this back on ourselves so we can proxy it again
    proxy.web(req, res, {
      target: remoteHost
      changeOrigin: true
      autoRewrite: true
    })

    return req.pipe(t)

  errorHandler: (e, req, res, remoteHost, proxyRes) ->
    # debugger
    remoteHost ?= req.cookies["__cypress.remoteHost"]

    url = @url.resolve(remoteHost, req.url)

    ## disregard ENOENT errors (that means the file wasnt found)
    ## which is a perfectly acceptable error (we account for that)
    if process.env["NODE_ENV"] isnt "production" and e and e.code isnt "ENOENT"
      console.error(e.stack)
      debugger

    @Log.info "error handling request", url: url, error: e

    filePath = switch
      when f = req.formattedUrl
        "file://#{f}"
      else
        url

    ## using req here to give us an opportunity to
    ## write to req.formattedUrl
    htmlPath = @path.join(process.cwd(), "lib/html/initial_500.html")
    # console.log "res status"
    # res.writeHead 501, {
      # "Content-Type": "text/plain"
    # }
    # res.end("DIE!")
    # res.end("WTF!")
    # res.status(501).render(htmlPath, {
      # url: filePath
      # fromFile: !!req.formattedUrl
    # }#, (err, html) ->
    #   proxyRes.writeHead 501, {"Content-Type": "text/html"}
    #   proxyRes.end(html)
    # )
    # res.end()

SecretSauce.RemoteInitial =
  _handle: (req, res, next, Domain) ->
    { _ } = SecretSauce

    inject = "
      <script type='text/javascript'>
        window.onerror = function(){
          parent.onerror.apply(parent, arguments);
        }
      </script>
      <script type='text/javascript' src='/__cypress/static/js/sinon.js'></script>
      <script type='text/javascript'>
        var Cypress = parent.Cypress;
        if (!Cypress){
          throw new Error('Cypress must exist in the parent window!');
        };
        Cypress.onBeforeLoad(window);
      </script>
    "

    d = Domain.create()

    d.on 'error', (e) => @errorHandler(e, req, res)

    d.run =>
      ## first check to see if this url contains a FQDN
      ## if it does then its been rewritten from an absolute-domain
      ## into a absolute-path-relative link, and we should extract the
      ## remoteHost from this URL
      remoteHost = @getOriginFromFqdnUrl(req) ? req.cookies["__cypress.remoteHost"]

      @Log.info "handling initial request", url: req.url, remoteHost: remoteHost

      ## we must have the remoteHost which tell us where
      ## we should request the initial HTML payload from
      if not remoteHost
        throw new Error("Missing remoteHost cookie!")

      # @overrideReqUrl(req, remoteHost)

      content = @getContent(req, res, remoteHost)

      content.on "error", (e) => @errorHandler(e, req, res, remoteHost)

      content
      .pipe(@injectContent(inject))
      .pipe(res)

  getOriginFromFqdnUrl: (req) ->
    ## if we find an origin from this req.url
    ## then return it, and reset our req.url
    ## after stripping out the origin and ensuring
    ## our req.url starts with only 1 leading slash
    if origin = @UrlHelpers.getOriginFromFqdnUrl(req.url)
      req.url = "/" + req.url.replace(origin, "").replace(/^\/+/, "")

      ## return the origin
      return origin

  getContent: (req, res, remoteHost) ->
    switch remoteHost
      ## serve from the file system because
      ## we are using cypress as our weberver
      when "<root>"
        @getFileContent(req, res, remoteHost)

      ## else go make an HTTP request to the
      ## real server!
      else
        @getHttpContent(req, res, remoteHost)

  getHttpContent: (req, res, remoteHost) ->
    { _ } = SecretSauce

    ## prepends req.url with remoteHost
    remoteUrl = @url.resolve(remoteHost, req.url)

    tr = @trumpet()

    rewrite = (selector, attr, fn) ->
      tr.selectAll selector, (elem) ->
        elem.getAttribute attr, (val) ->
          elem.setAttribute attr, fn(val)

    rewrite "[href^='//']", "href", (href) ->
      "/" + req.protocol + ":" + href

    rewrite "form[action^='//']", "action", (action) ->
      "/" + req.protocol + ":" + action

    rewrite "form[action^='http']", "action", (action) ->
      if action.startsWith(remoteHost)
        action.replace(remoteHost, "")
      else
        "/" + action

    rewrite "[href^='http']", "href", (href) ->
      if href.startsWith(remoteHost)
        href.replace(remoteHost, "")
      else
        "/" + href

    setCookies = (initial, remoteHost) ->
      res.cookie("__cypress.initial", initial)
      res.cookie("__cypress.remoteHost", remoteHost)

    thr = @through (d) -> @queue(d)

    ## set the headers on the request
    ## this will naturally forward cookies or auth tokens
    ## or anything else which should be proxied
    ## for some reason adding host / accept-encoding / accept-language
    ## would completely bork getbootstrap.com
    # headers = _.omit(req.headers, "host", "accept-encoding", "accept-language")

    ## proxy each of the headers include cookie, which will contain
    ## our cypress cookies. thats okay though because we always
    ## add them afterwards

    # opts = {url: remoteUrl, headers: headers, followRedirect: false}
    opts = {url: remoteUrl, followRedirect: false}
    # opts = {url: remoteUrl, method: req.method, gzip: true, headers: headers}

    ## pass on the form values from our body
    # if req.method is "POST"
      # opts.form = req.body

    rq = @request(opts)

    rq.on "error", (err) ->
      thr.emit("error", err)

    rq.on "response", (incomingRes) =>
      if /^30(1|2|7|8)$/.test(incomingRes.statusCode)
        ## we cannot redirect them to an external site
        ## instead we need to reset the __cypress.remoteHost cookie to
        ## the location headers, and then redirect the user to the remaining
        ## url but back to ourselves!

        ## we go through this merge because the spec states that the location
        ## header may not be a FQDN. If it's not (sometimes its just a /) then
        ## we need to merge in the missing url parts
        newUrl = new @jsUri @UrlHelpers.merge(remoteUrl, incomingRes.headers.location)

        ## set cookies to initial=true and our new remoteHost origin
        setCookies(true, newUrl.origin())

        @Log.info "redirecting to new url", status: incomingRes.statusCode, url: newUrl.toString()

        ## finally redirect our user agent back to our domain
        ## after stripping the external origin
        res.redirect newUrl.toString().replace(newUrl.origin(), "")
      else
        if not incomingRes.headers["content-type"]
          throw new Error("Missing header: 'content-type'")
        @Log.info "received absolute file content"
        res.contentType(incomingRes.headers['content-type'])

        ## turn off __cypress.initial by setting false here
        setCookies(false, remoteHost)

        # rq.pipe(thr)
        rq.pipe(tr).pipe(thr)

    ## proxy the request body, content-type, headers
    ## to the new rq
    req.pipe(rq)

    thr

  injectContent: (toInject) ->
    toInject ?= ""

    @through2.obj (chunk, enc, cb) ->
      src = chunk.toString()
            .replace(/<head>/, "<head> #{toInject}")

      cb(null, src)

  getFileContent: (req, res, remoteHost) ->
    { _ } = SecretSauce

    args = _.compact([
      @app.get("cypress").projectRoot,
      # @app.get("cypress").rootFolder,
      req.url
    ])

    ## strip trailing slashes because no file
    ## ever has one
    file = @path.join(args...).replace(/\/+$/, "")

    req.formattedUrl = file

    @Log.info "getting relative file content", file: file

    res.cookie("__cypress.initial", false)
    res.cookie("__cypress.remoteHost", remoteHost)

    @fs.createReadStream(file, "utf8")

  errorHandler: (e, req, res, remoteHost) ->
    debugger
    remoteHost ?= req.cookies["__cypress.remoteHost"]

    url = @url.resolve(remoteHost, req.url)

    ## disregard ENOENT errors (that means the file wasnt found)
    ## which is a perfectly acceptable error (we account for that)
    if process.env["NODE_ENV"] isnt "production" and e.code isnt "ENOENT"
      console.error(e.stack)
      debugger

    @Log.info "error handling initial request", url: url, error: e

    filePath = switch
      when f = req.formattedUrl
        "file://#{f}"
      else
        url

    ## using req here to give us an opportunity to
    ## write to req.formattedUrl
    htmlPath = @path.join(process.cwd(), "lib/html/initial_500.html")
    res.status(500).render(htmlPath, {
      url: filePath
      fromFile: !!req.formattedUrl
    })

if module?
  module.exports = SecretSauce
else
  SecretSauce
