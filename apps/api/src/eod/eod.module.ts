import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { EodController } from './eod.controller';
import { EodService } from './eod.service';

@Module({
  imports: [AuthModule],
  controllers: [EodController],
  providers: [EodService],
  exports: [EodService],
})
export class EodModule {}
