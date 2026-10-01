import { Module, NestModule, MiddlewareConsumer, Global } from '@nestjs/common';
import { APP_GUARD, APP_INTERCEPTOR } from '@nestjs/core';
import { RateLimiterGuard } from './rate-limiter.guard';
import { RequestLoggerMiddleware } from './request-logger.middleware';
import { IdempotencyInterceptor } from './idempotency.interceptor';
import { SanitizePipe } from './sanitize.pipe';
import { DatabaseModule } from '../database/database.module';

@Global()
@Module({
  imports: [DatabaseModule],
  providers: [
    {
      provide: APP_GUARD,
      useClass: RateLimiterGuard,
    },
    {
      provide: APP_INTERCEPTOR,
      useClass: IdempotencyInterceptor,
    },
    SanitizePipe,
  ],
  exports: [SanitizePipe],
})
export class SecurityModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    consumer.apply(RequestLoggerMiddleware).forRoutes('*');
  }
}
