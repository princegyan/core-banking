import { Module } from '@nestjs/common';

import { AuthModule } from '../auth/auth.module';

import { LoanProductsController } from './loan-products.controller';
import { LoanProductsService } from './loan-products.service';

@Module({
  imports: [AuthModule],
  controllers: [LoanProductsController],
  providers: [LoanProductsService],
  exports: [LoanProductsService],
})
export class LoanProductsModule {}
