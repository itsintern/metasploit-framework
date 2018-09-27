# -*- coding: binary -*-

class Msf::Ui::Console::CommandDispatcher::Developer

  include Msf::Ui::Console::CommandDispatcher

  @@irb_opts = Rex::Parser::Arguments.new(
    "-h" => [ false, "Help banner."                                   ],
    "-e" => [ true,  "Expression to evaluate."                        ])

  def initialize(driver)
    super
  end

  def name
    'Developer'
  end

  def commands
    {
      'irb'        => 'Drop into irb scripting mode',
      'pry'        => 'Open a Pry session on the current module or Framework',
      'edit'       => 'Edit the current module or a file with the preferred editor',
      'reload_lib' => 'Reload one or more library files from specified paths',
      'log'        => 'Displays framework.log starting at the bottom if possible'
    }
  end

  def git?
    unless Msf::Util::Helper.which("git")
      print_error "'git' is not found."
      return false
    end

    unless File.directory?(File.join(Msf::Config.install_root, ".git"))
      print_error "Framework installation is not a git repository. \n    Did you install using a nightly installer or package manager?"
      return false
    end

    true
  end

  def local_editor
    framework.datastore['LocalEditor'] || Rex::Compat.getenv('VISUAL') || Rex::Compat.getenv('EDITOR')
  end

  def local_pager
    framework.datastore['LocalPager'] || Rex::Compat.getenv('PAGER') || Rex::Compat.getenv('MANPAGER')
  end

  # XXX: This will try to reload *any* .rb and break on modules
  def reload_file(path)
    unless File.exist?(path) && path.end_with?('.rb')
      print_error("#{path} must exist and be a .rb file")
      return
    end

    # The file must exist to reach this, so we try our best here
    if path =~ %r{^(?:\./)?modules/}
      print_error("Reloading Metasploit modules is not supported (try 'reload')")
      return
    end

    print_status("Reloading #{path}")
    load path
  end

  def reload_diff_files
    unless git?
      return
    end
    output, status = Open3.capture2e *%w(git diff --name-only)
    if status.success?
      files = output.split("\n")
      files.each { |file| reload_file(file) }
    else
      print_error output
    end
  end

  def cmd_irb_help
    print_line "Usage: irb"
    print_line
    print_line "Execute commands in a Ruby environment"
    print @@irb_opts.usage
  end

  #
  # Goes into IRB scripting mode
  #
  def cmd_irb(*args)
    expressions = []

    # Parse the command options
    @@irb_opts.parse(args) do |opt, idx, val|
      case opt
      when '-e'
        expressions << val
      when '-h'
        cmd_irb_help
        return false
      end
    end

    if expressions.empty?
      print_status("Starting IRB shell...\n")

      begin
        Rex::Ui::Text::IrbShell.new(binding).run
      rescue
        print_error("Error during IRB: #{$!}\n\n#{$@.join("\n")}")
      end

      # Reset tab completion
      if (driver.input.supports_readline)
        driver.input.reset_tab_completion
      end
    else
      expressions.each { |expression| eval(expression, binding) }
    end
  end

  #
  # Tab completion for the irb command
  #
  def cmd_irb_tabs(str, words)
    return [] if words.length > 1
    @@irb_opts.fmt.keys
  end

  def cmd_pry_help
    print_line 'Usage: pry'
    print_line
    print_line 'Open a Pry session on the current module or Framework.'
    print_line
  end

  #
  # Open a Pry session on the current module or Framework
  #
  def cmd_pry(*args)
    if args.include?('-h')
      cmd_pry_help
      return
    end

    begin
      require 'pry'
    rescue LoadError
      print_error('Failed to load Pry, try "gem install pry"')
      return
    end

    print_status('Starting Pry shell...')

    unless active_module
      print_status("You are in the \"framework\" object\n")
      framework.pry
      return
    end

    print_status("You are in #{active_module.fullname}\n")
    active_module.pry
  end

  def cmd_edit_help
    print_line 'Usage: edit [file/to/edit]'
    print_line
    print_line "Edit the currently active module or a local file with #{local_editor}."
    print_line 'If a library file is specified, it will automatically be reloaded after editing.'
    print_line "Otherwise, you can reload the active module with 'reload' or 'rerun'."
    print_line
  end

  #
  # Edit the current module or a file with the preferred editor
  #
  def cmd_edit(*args)
    editing_module = false

    if args.length > 0
      path = File.expand_path(args[0])
    elsif active_module
      editing_module = true
      path = active_module.file_path
    end

    unless path
      print_error('Nothing to edit. Try using a module first or specifying a library file to edit.')
      return
    end

    editor = local_editor

    unless editor
      editor = 'vim'
      print_warning("LocalEditor or $VISUAL/$EDITOR should be set. Falling back on #{editor}.")
    end

    # XXX: No vprint_status in this context?
    # XXX: VERBOSE is a string instead of Bool??
    print_status("Launching #{editor} #{path}") if framework.datastore['VERBOSE'].to_s == 'true'

    unless system(*editor.split, path)
      print_error("Could not execute #{editor} #{path}")
      return
    end

    return if editing_module

    reload_file(path)
  end

  #
  # Tab completion for the edit command
  #
  def cmd_edit_tabs(str, words)
    tab_complete_filenames(str, words)
  end

  def cmd_reload_lib_help
    cmd_reload_lib '-h'
  end

  #
  # Reload one or more library files from specified paths
  #
  def cmd_reload_lib(*args)

    opts = OptionParser.new do |opts|
      opts.banner = 'Usage: reload_lib lib/to/reload.rb [...]'
      opts.separator 'Reload one or more library files from specified paths.'
      opts.separator ''

      opts.on '-h', '--help', 'Help banner.' do
        return print(opts.help)
      end

      opts.on '-a', '--all', 'Reload all changed files in your current git working tree.' do
        reload_diff_files
        return
      end

    end

    rest = opts.order(args)
    rest.each { |path| reload_file(path) }
  end

  #
  # Tab completion for the reload_lib command
  #
  def cmd_reload_lib_tabs(str, words)
    tab_complete_filenames(str, words)
  end

  def cmd_log_help
    print_line 'Usage: log'
    print_line
    print_line 'Displays framework.log starting at the bottom if possible.'
    print_line "For full effect, 'setg LogLevel 3' before running modules."
    print_line
    print_line "Log location: #{File.join(Msf::Config.log_directory, 'framework.log')}"
    print_line
  end

  #
  # Displays framework.log starting at the bottom if possible
  #
  def cmd_log(*args)
    path = File.join(Msf::Config.log_directory, 'framework.log')

    # XXX: +G isn't portable and may hang on large files
    pager = local_pager.to_s.include?('less') ? "#{local_pager} +G" : local_pager

    unless pager
      pager = 'tail -n 24'
      print_warning("LocalPager or $PAGER/$MANPAGER should be set. Falling back on #{pager}.")
    end

    # XXX: No vprint_status in this context?
    # XXX: VERBOSE is a string instead of Bool??
    print_status("Launching #{pager} #{path}") if framework.datastore['VERBOSE'].to_s == 'true'

    unless system(*pager.split, path)
      print_error("Could not execute #{pager} #{path}")
    end
  end

end
