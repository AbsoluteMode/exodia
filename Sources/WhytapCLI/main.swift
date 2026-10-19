import Foundation
import WhytapCaseKit

let usage = """
usage: whytap <command>

commands:
  projects            list Case projects
  keys [-p project]   list key names
  run [-p project] [--only A,B] -- <command>
                      run a command with Case keys as environment variables
"""

FileHandle.standardError.write(Data((usage + "\n").utf8))
exit(64)
