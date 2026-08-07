# ClawHunt Sink Reference Patterns

## SQL Injection Sinks
- Python: `cursor.execute()`, `connection.query()`, f-string/concat in SQL
- Node.js: raw query strings with `${var}` or `+ var` interpolation, `pool.query()`
- Java: `Statement.executeQuery()`, `PreparedStatement` with string concat
- Go: `db.Query()` with string concatenation, `sql.DB.Exec()`
- PHP: `mysqli_query()`, PDO prepare without proper binding

## Command Injection Sinks
- Python: `os.system()`, `subprocess.call/run/Popen(shell=True)`, `eval()`, `exec()`
- Node.js: `child_process.exec/spawnSync()`, `eval()`, `Function()` constructor
- Java: `Runtime.exec()`, `ProcessBuilder`
- Go: `exec.CommandContext()` with shell, `os/exec` with user input in args
- Ruby: backtick execution `` `cmd` ``, `system()`, `%x{}`

## XSS Sinks
- React: `dangerouslySetInnerHTML={{__html: userInput}}`
- Vue: `v-html="userInput"`
- Angular: `[innerHTML]="userInput"`, `bypassSecurityTrustHtml()`
- jQuery/JS: `$(el).html(userInput)`, `element.innerHTML = userInput`
- Template engines: unescaped output in EJS `<%= var>` vs `<%- var>`, Pug interpolation

## SSRF Sinks
- Node.js: `fetch(url)`, `axios.get()`, `http.request()` where URL contains user input
- Python: `requests.get()`, `urllib.request.urlopen()` with user-controlled URLs
- Java: `HttpClient.newRequest()`, `URL.openConnection()`
- Go: `http.Get()`, `http.Client.Do()` with user-controlled URLs
- Any HTTP client where scheme/host/port comes from string concatenation with user input

## Path Traversal Sinks
- Python: `open(userInput)`, `os.path.join()` without validation, `shutil.copy()`
- Node.js: `fs.readFile()`, `fs.createReadStream()` with user-controlled paths
- Java: `FileInputStream`, `Files.readAllBytes()`
- Go: `os.Open()`, `ioutil.ReadFile()`
- Archive extraction (zip/tar) without path canonicalization

## Deserialization Sinks
- Python: `pickle.load()`, `yaml.load()` (unsafe loader), `marshal.loads()`
- Java: `ObjectInputStream.readObject()`, `XStream.fromXML()`
- Node.js: `vm.runInNewContext()` with user input, unsafe JSON.parse to class instances
- PHP: `unserialize()`, `php://input` deserialization

## NoSQL Injection Sinks
- MongoDB/Mongoose: `{ $where: userInput }`, `{ $regex: userInput }`
- Elasticsearch: query strings from user input without escaping
- Redis: command injection via unsanitized keys/commands

## LDAP Injection Sinks
- Python `ldap3`: filter strings with user input
- Java JNDI/LDAP: concatenated search filters
- Node.js ldapjs: unsanitized filter parameters

## Template Injection Sinks
- Jinja2: `render_template_string(userInput)`
- Twig: `createTemplate(userInput)`
- Handlebars/EJS: unescaped template compilation from user input
- Java Freemarker/Thymeleaf: dynamic template sources from user input
