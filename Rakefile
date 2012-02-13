require 'rake'
require 'rake/testtask'
require 'rake/clean'

require 'rubygems/package_task'
require 'rdoc/task'

task :default => [:rdoc, :test]

Rake::RDocTask.new do |rd|
    rd.rdoc_dir = 'doc'
    rd.title = 'RSQL Documentation'
    rd.main = "README.rdoc"
    rd.rdoc_files.include('README.rdoc', 'LICENSE', 'lib/**/*.rb')
end

Rake::TestTask.new do |t|
  t.libs << 'test'
  t.test_files = FileList['test/test_*.rb']
end

begin
    # don't require rcov if they haven't installed it
    require 'rcov/rcovtask'
    Rcov::RcovTask.new do |t|
        t.libs << "test"
        t.test_files = FileList['test/test*.rb']
    end
rescue LoadError
end

spec = Gem::Specification.new do |s|
    rsql_version = nil
    File.open("lib/rsql.rb").each do |line|
        if line =~ /VERSION\s*=\s*'([^']+)'/
            rsql_version = $1
            break
        end
    end
    s.name        = 'rsql'
    s.version     = rsql_version
    s.author      = 'Brad Robel-Forrest'
    s.email       = 'brad+rsql@gigglewax.com'
    s.summary     = 'Ruby-based MySQL command line with recipes.'
    s.description = <<-EOF.delete "\n"
RSQL makes working with a MySQL command line more convenient through
the use of recipes and embedding the common operation of using a SSH
connection to an intermediary host for access to the MySQL server.
EOF
    s.homepage = 'https://rubygems.org/gems/rsql'
    s.required_ruby_version = '>=1.8.0'
    s.add_dependency('net-ssh', '>=2.1.0')
    s.add_dependency('mysqlplus', '>=0.1.2')
    s.add_development_dependency('mocha', '>=0.9.12')
    s.add_development_dependency('rake')
    s.add_development_dependency('rdoc')
    s.add_development_dependency('rcov')
    s.require_paths = ['lib']
    s.files         = `git ls-files`.split($/)
    s.files.delete('Rakefile')
    s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
    s.executables   = `git ls-files -- bin/*`.split($/).map{ |f| File.basename(f) }
    s.rdoc_options <<
        '--title' << 'RSQL Documentation' <<
        '--main' << 'README.rdoc'
    s.extra_rdoc_files = ['README.rdoc', 'LICENSE']
end

Gem::PackageTask.new(spec) do |pkg|
   pkg.need_zip = true
   pkg.need_tar = true
end
