// Simple logger with timestamps and colored output

const colors = {
  reset: '\x1b[0m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  gray: '\x1b[90m',
};

export enum LogLevel {
  DEBUG = 0,
  INFO = 1,
  WARN = 2,
  ERROR = 3,
}

class Logger {
  private logLevel: LogLevel;

  constructor() {
    const level = process.env.LOG_LEVEL?.toUpperCase() || 'INFO';
    this.logLevel = LogLevel[level as keyof typeof LogLevel] || LogLevel.INFO;
  }

  private formatTimestamp(): string {
    return new Date().toISOString();
  }

  private log(level: LogLevel, levelStr: string, color: string, message: string, ...args: any[]): void {
    if (level >= this.logLevel) {
      const timestamp = this.formatTimestamp();
      const prefix = `${colors.gray}[${timestamp}]${colors.reset} ${color}[${levelStr}]${colors.reset}`;
      console.log(prefix, message, ...args);
    }
  }

  debug(message: string, ...args: any[]): void {
    this.log(LogLevel.DEBUG, 'DEBUG', colors.blue, message, ...args);
  }

  info(message: string, ...args: any[]): void {
    this.log(LogLevel.INFO, 'INFO', colors.green, message, ...args);
  }

  warn(message: string, ...args: any[]): void {
    this.log(LogLevel.WARN, 'WARN', colors.yellow, message, ...args);
  }

  error(message: string, error?: Error | unknown, ...args: any[]): void {
    if (error instanceof Error) {
      this.log(LogLevel.ERROR, 'ERROR', colors.red, `${message}: ${error.message}`, ...args);
      if (this.logLevel <= LogLevel.DEBUG && error.stack) {
        console.error(colors.gray + error.stack + colors.reset);
      }
    } else if (error) {
      this.log(LogLevel.ERROR, 'ERROR', colors.red, message, error, ...args);
    } else {
      this.log(LogLevel.ERROR, 'ERROR', colors.red, message, ...args);
    }
  }

  // Specialized logging for blockchain events
  block(blockNumber: bigint | number, message: string): void {
    this.info(`${colors.cyan}[Block ${blockNumber}]${colors.reset} ${message}`);
  }

  tx(hash: string, message: string): void {
    this.info(`${colors.magenta}[Tx ${hash}]${colors.reset} ${message}`);
  }

  chain(chainId: number, message: string): void {
    this.info(`${colors.blue}[Chain ${chainId}]${colors.reset} ${message}`);
  }
}

// Export singleton instance
export const logger = new Logger();

// Export convenience functions
export const debug = logger.debug.bind(logger);
export const info = logger.info.bind(logger);
export const warn = logger.warn.bind(logger);
export const error = logger.error.bind(logger);

export default logger;