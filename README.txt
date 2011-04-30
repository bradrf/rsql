= rsql

https://github.com/bradrf/rsql


== DESCRIPTION

This is an application to make working with a SQL command line more
convenient by allowing interaction with Ruby in addition to embedding
the common operation of using a SSH connection to an intermediary host
for access to the SQL server.

Aside from the standard MySQL command syntax, the following
functionality allows for a little more expressive processing.

Multiple commands can be issued in one set by separation with
semicolons.

Generating SQL
--------------

Ruby code may be called to generate the SQL that is to be executed.
This is done by starting any command string with a period. If the
final result of evaluating the command string is another string, it is
executed as SQL. Any semicolons meant to be processed by Ruby must be
escaped. Example:

 rsql> . puts 'hello world!' \\; 'select * from Account'

Utilizing Canned Methods
------------------------

Commands can be stored in the .rsqlrc file in your HOME directory to
expose methods that may be invoked to generate SQL with variable
interpolation. Use of the 'register' helper is recommended for this
approach. These can then be called in the same way as above. Example:

In the .sqlrc file...

 register :users_by_email, :email %q{
   SELECT * FROM Users WHERE email = '\#\{email\}'
 }

...then from the prompt:

 rsql> . users_by_email 'brad@gigglewax.com'

If a block is provided to the registration, it will be called as a
method. Example:

In the .sqlrc file...

 register :dumby, :hello do |*args|
   p args
 end

 rsql> . dumby :world

All registered methods can be listed using the built-in 'list'
command.

Changes to a sourced file can be reloaded using the built-in 'reload'
command.

Processing Column Data
----------------------

Ruby can be called to process any data on a per-column basis before a
displayer is used to render the output. In this way, one can write
Ruby to act like MySQL functions on all the data for a given column,
converting it into a more readable value. A bang indicator (exlamation
point: !) is used to demarcate a mapping of column names to Ruby
methods that should be invoked to processes content. Example:

 rsql> select IpAddress from Devices ; ! IpAddress => bin_to_str

This will call 'bin_to_str' for each 'IpAddress' returned from the
query. Mulitple mappings are separated by a comma. These mappings can
also be utilized in a canned method. Example:

 register :all_ips, 'select IpAddress from Devices', 'IpAddress' => :bin_to_str

Redirection
-----------

Output from one or more queries may be post-processed dynamically. If
any set of commands is follwed by a greater-than symbol, all results
will be stored in a global $results array (with field information
stored in $fields) and the final Ruby code will be evaluated with
access to them. Any result of the evaluation that is a string is then
executed as SQL. Example:

 rsql> select * from Account; select * from Users; > $results.each {|r| p r}


== LICENSE

Copyright (C) 2011 by Brad Robel-Forrest <brad+rsql@gigglewax.com>

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
